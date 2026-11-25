defmodule Crdt.TreedocTest do
  use ExUnit.Case, async: true

  alias Crdt.Causal
  alias Crdt.Treedoc

  defp doc(pairs), do: doc(pairs, [])
  defp doc(pairs, dead) do
    d = Enum.reduce(pairs, Treedoc.new(), fn {p, c}, d ->
      Treedoc.apply_op(d, %{op: :ins, pos: p, ch: c})
    end)
    Enum.reduce(dead, d, fn p, d -> Treedoc.apply_op(d, %{op: :del, pos: p}) end)
  end

  defp write(d, i, text, seq0, node) do
    {:ok, posids} = Treedoc.prepare_insert(d, i, String.graphemes(text), seq0, node)
    d = Enum.reduce(posids, d, fn {p, c}, d -> Treedoc.apply_op(d, %{op: :ins, pos: p, ch: c}) end)
    {d, posids}
  end

  test "in-order sort, siblings by {seq, node}" do
    v1 = [
      {[{1, 1, :a}], "c"},
      {[{1, 1, :a}, {0, 2, :a}], "b"},
      {[{1, 1, :a}, {1, 3, :a}], "d"},
      {[{1, 1, :a}, {0, 2, :a}, {0, 4, :a}], "a"}
    ]

    assert Treedoc.text(doc(v1)) == "abcd"
    assert Treedoc.text(doc(v1, [[{1, 1, :a}, {0, 2, :a}]])) == "acd"
  end

  test "last step of each new PosID carries its own {seq, node}" do
    {d, _} = write(Treedoc.new(), 0, "hola", 0, :a)
    {_, posids} = write(d, 2, "XYZ", 4, :b)
    lasts = Enum.map(posids, fn {p, _} -> List.last(p) end)
    assert Enum.map(lasts, fn {_bit, seq, node} -> {seq, node} end) == [{5, :b}, {6, :b}, {7, :b}]
  end

  test "invalid positions are rejected" do
    {d, _} = write(Treedoc.new(), 0, "ab", 0, :a)
    assert Treedoc.prepare_insert(d, 3, ["x"], 2, :a) == {:error, :invalid_index}
    assert Treedoc.prepare_insert(d, -1, ["x"], 2, :a) == {:error, :invalid_index}
    assert Treedoc.prepare_delete(d, 1, 2) == {:error, :invalid_index}
    assert Treedoc.prepare_delete(d, 0, 0) == {:ok, []}
  end

  test "3 replicas converge with random delivery order (50 runs)" do
    for _ <- 1..50 do
      {replicas, ops} = simulate()

      texts =
        for r <- replicas do
          Treedoc.text(deliver_all(r, Enum.shuffle(ops)))
        end

      assert length(Enum.uniq(texts)) == 1
    end
  end

  test "pasting 1000 chars is fast and in order" do
    text = String.duplicate("abcdefghij", 100)
    {us, {d, _}} = :timer.tc(fn -> write(Treedoc.new(), 0, text, 0, :a) end)

    assert Treedoc.text(d) == text
    assert us < 500_000
  end

  test "multi-codepoint graphemes occupy one position" do
    {d, _} = write(Treedoc.new(), 0, "a👍b", 0, :a)
    assert Treedoc.text(d) == "a👍b"
    assert length(Treedoc.visible(d)) == 3
  end

  defp posid_at(d, i), do: d |> Treedoc.visible() |> Enum.at(i) |> elem(0)

  defp apply_ins(d, posids) do
    Enum.reduce(posids, d, fn {p, c}, d -> Treedoc.apply_op(d, %{op: :ins, pos: p, ch: c}) end)
  end

  test "insert after an anchor gives the same PosIDs as insert at the index" do
    {d, _} = write(Treedoc.new(), 0, "hola", 0, :a)
    d = Treedoc.apply_op(d, %{op: :del, pos: posid_at(d, 1)})

    for i <- 0..3 do
      anchor = if i == 0, do: [], else: posid_at(d, i - 1)

      assert Treedoc.prepare_insert_after(d, anchor, ["x", "y"], 4, :b) ==
               Treedoc.prepare_insert(d, i, ["x", "y"], 4, :b)
    end
  end

  test "an anchor keeps the text next to its char after a concurrent edit" do
    {base, _} = write(Treedoc.new(), 0, "abc", 0, :a)
    b = posid_at(base, 1)

    # :b inserts X between b and c while :a, still looking at "abc", anchors Y after b.
    {with_x, x} = write(base, 2, "X", 0, :b)
    {:ok, y} = Treedoc.prepare_insert_after(with_x, b, ["Y"], 3, :a)

    r1 = apply_ins(with_x, y)
    r2 = apply_ins(apply_ins(base, y), x)

    assert Treedoc.text(r1) == "abYXc"
    assert Treedoc.text(r2) == "abYXc"
  end

  test "the anchor may be a tombstone, [] is the start, an unknown anchor is rejected" do
    {d, _} = write(Treedoc.new(), 0, "abc", 0, :a)
    dead = Treedoc.apply_op(d, %{op: :del, pos: posid_at(d, 1)})

    {:ok, y} = Treedoc.prepare_insert_after(dead, posid_at(d, 1), ["Y"], 3, :a)
    assert Treedoc.text(apply_ins(dead, y)) == "aYc"

    {:ok, z} = Treedoc.prepare_insert_after(d, [], ["Z"], 3, :a)
    assert Treedoc.text(apply_ins(d, z)) == "Zabc"

    assert {:ok, [_]} = Treedoc.prepare_insert_after(Treedoc.new(), [], ["x"], 0, :a)
    assert Treedoc.prepare_insert_after(d, [{1, 99, :zz}], ["x"], 3, :a) == {:error, :unknown_anchor}
    assert Treedoc.prepare_insert_after(d, :nope, ["x"], 3, :a) == {:error, :unknown_anchor}
  end

  test "prepare_delete_ids drops dead and repeated ids, rejects unknown ones" do
    {d, _} = write(Treedoc.new(), 0, "abc", 0, :a)
    [a, b, c] = Enum.map(Treedoc.visible(d), &elem(&1, 0))
    d = Treedoc.apply_op(d, %{op: :del, pos: b})

    assert Treedoc.prepare_delete_ids(d, [a, b, a, c]) == {:ok, [a, c]}
    assert Treedoc.prepare_delete_ids(d, [[{1, 99, :zz}]]) == {:error, :unknown_id}
    assert Treedoc.prepare_delete_ids(d, :nope) == {:error, :invalid_ids}
  end

  defp simulate do
    nodes = [:a, :b, :c]
    initial = Map.new(nodes, fn n -> {n, %{doc: Treedoc.new(), vc: %{}, buffer: []}} end)

    {replicas, ops} =
      Enum.reduce(1..15, {initial, []}, fn _, {reps, ops} ->
        n = Enum.random(nodes)
        {r, new} = edit(receive_some(reps[n], ops), n)
        {Map.put(reps, n, r), ops ++ new}
      end)

    {Map.values(replicas), ops}
  end

  defp receive_some(r, []), do: r
  defp receive_some(r, ops) do
    if :rand.uniform(2) == 1, do: receive_one(r, Enum.random(ops)), else: r
  end

  defp edit(r, n) do
    visibles = length(Treedoc.visible(r.doc))
    seq0 = Map.get(r.vc, n, 0)

    ops =
      if visibles > 0 and :rand.uniform(3) == 1 do
        {:ok, [p]} = Treedoc.prepare_delete(r.doc, Enum.random(0..(visibles - 1)), 1)
        [%{op: :del, from: n, vc: Map.put(r.vc, n, seq0 + 1), pos: p}]
      else
        chars = String.graphemes(Enum.random(["a", "bc"]))
        {:ok, ps} = Treedoc.prepare_insert(r.doc, Enum.random(0..visibles), chars, seq0, n)

        for {{p, c}, seq} <- Enum.with_index(ps, seq0 + 1) do
          %{op: :ins, from: n, vc: Map.put(r.vc, n, seq), pos: p, ch: c}
        end
      end

    r = Enum.reduce(ops, r, fn op, r ->
      %{r | doc: Treedoc.apply_op(r.doc, op), vc: Causal.deliver(r.vc, op)}
    end)

    {r, ops}
  end

  defp receive_one(r, op) do
    {vc, buffer, applied, _} = Crdt.Causal.receive(r.vc, r.buffer, op)
    doc = Enum.reduce(applied, r.doc, &Treedoc.apply_op(&2, &1))
    %{r | vc: vc, buffer: buffer, doc: doc}
  end

  defp deliver_all(r, ops) do
    r = Enum.reduce(ops, r, fn op, r -> receive_one(r, op) end)
    assert r.buffer == []
    r.doc
  end
end
