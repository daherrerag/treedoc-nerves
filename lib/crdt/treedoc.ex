defmodule Crdt.Treedoc do
  @moduledoc """
  Treedoc CRDT.
  One character per atom, keyed by its PosID.

  * PosID: `{bit, seq, node}` with
  `bit in 0..1`,
  `seq >= 1`,
  `node` an atom `:"doc@<ip>"`.
  * State: `%{chars: %{PosID => grapheme}, dead: MapSet.new(PosID)}`.
  * Order: in-order traversal: left child (bit 0) < parent < right child (bit 1).
  * Insert: multi-character inserts are placed as a balanced subtree.
  * Tie-break on a duplicate PosID — keep `min(existing, new)` grapheme.
  """

   @doc "Empty document: no atoms, no tombstones."
  def new, do: %{chars: %{}, dead: MapSet.new()}

  @doc """
  Strict less-than between two PosIDs, the in-order walk of [T] §3.1.

  * `[]` is the virtual root; it is never stored in `chars` but is used as the
    left boundary when inserting at index 0.
  * A left child (`bit = 0`) sorts before its parent, a right child (`bit = 1`)
    after it.
  * When two sibling steps differ, Erlang tuple order `{bit, seq, node}` breaks
    the tie — exactly as in B's `menor?/2`.
  """
  def less_than?([], []), do: false
  def less_than?([], [{bit, _, _} | _]), do: bit == 1
  def less_than?([{bit, _, _} | _], []), do: bit == 0
  def less_than?([x | rest_a], [x | rest_b]), do: less_than?(rest_a, rest_b)
  def less_than?([x | _], [y | _]), do: x < y

  @doc "Full order as a list of `{PosID, char}` pairs, tombstones included."
  def ordered(doc) do
    Enum.sort(Map.to_list(doc.chars), fn {p1, _}, {p2, _} -> less_than?(p1, p2) end)
  end

  @doc "Visible chars (tombstones removed), in order."
  def visible(doc), do: reject_dead(ordered(doc), doc.dead)

  @doc "The visible text, as a binary."
  def text(doc) do
    Enum.map_join(visible(doc), fn {_, ch} -> ch end)
  end

  @doc """
  Picks PosIDs for inserting `chars` (a list of graphemes) at visible index `i`,
  starting at sequence number `seq0 + 1` for the first char and incrementing by
  one per char.  Returns `{:ok, [{PosID, grapheme}, ...]}` in text order,
  or `{:error, :invalid_index}`.

  The PosIDs form a balanced subtree rooted between the left neighbour `p`
  (visible char at `i-1`, or `[]`) and the right neighbour `f` (next char after
  `p` in the full order, tombstones included, or `nil`).
  """
  def prepare_insert(doc, i, chars, seq0, node) when is_integer(seq0) and seq0 >= 0 do
    order = ordered(doc)
    visibles = reject_dead(order, doc.dead)

    if is_integer(i) and i >= 0 and i <= length(visibles) do
      p = left_neighbour(visibles, i)
      place = {:between, p, right_neighbour(order, p)}
      placed = balance(Enum.with_index(chars, seq0 + 1), place, node)
      {:ok, in_text_order(placed)}
    else
      {:error, :invalid_index}
    end
  end

  @doc """
  Picks PosIDs for deleting `n` visible chars starting at index `i`.
  Returns `{:ok, [PosID, ...]}` or `{:error, :invalid_index}`.
  `i = 0, n = 0` returns `{:ok, []}` (no-op).
  """
  def prepare_delete(doc, i, n) do
    visibles = visible(doc)

    if is_integer(i) and is_integer(n) and i >= 0 and n >= 0 and i + n <= length(visibles) do
      {:ok, Enum.map(Enum.slice(visibles, i, n), fn {posid, _} -> posid end)}
    else
      {:error, :invalid_index}
    end
  end

  @doc """
  Applies one operation (`:ins` or `:del`) to the document.  Idempotent: applying the same op twice yields the same state.

  On insert, if the PosID is already present
  (concurrent insert at the same path
  only possible if `{seq, node}` collided,
  which the protocol prevents)
  keep the `min/2` of the two graphemes, exactly as B does.
  """
  def apply_op(doc, %{op: :ins, pos: posid, ch: ch}) do
    %{doc | chars: Map.update(doc.chars, posid, ch, fn other -> min(other, ch) end)}
  end

  def apply_op(doc, %{op: :del, pos: posid}) do
    %{doc | dead: MapSet.put(doc.dead, posid)}
  end

  # Build a balanced subtree: middle char between p and f, left half in the
  # left subtree of the middle, right half in its right subtree.  Each char
  # gets its own `{seq, node}` on the last step.
  defp balance([], _place, _node), do: []

  defp balance(chars, place, node) do
    {left, [{ch, seq} | right]} = Enum.split(chars, div(length(chars), 2))
    posid = place_at(place, seq, node)
    mid = [{posid, ch, seq}]

    mid ++
      balance(left, {:child, posid, 0}, node) ++
      balance(right, {:child, posid, 1}, node)
  end

  defp place_at({:between, p, f}, seq, node), do: new_posid(p, f, seq, node)
  defp place_at({:child, parent, bit}, seq, node), do: parent ++ [{bit, seq, node}]

  # The new PosID lands strictly between `p` (left) and `f` (right):
  #   * if `f` is in the subtree of `p` (`p` is a prefix of `f`), the new node
  #     is the left child of `f`  -> `f ++ [{0, seq, node}]`
  #   * otherwise (no right neighbour, or `f` is outside `p`'s subtree) the new
  #     node is the right child of `p` -> `p ++ [{1, seq, node}]`
  defp new_posid(p, nil, seq, node), do: p ++ [{1, seq, node}]
  defp new_posid(p, f, seq, node) do
    if List.starts_with?(f, p) do
      f ++ [{0, seq, node}]
    else
      p ++ [{1, seq, node}]
    end
  end

  # Re-order the placed chars by their seq so the caller receives them in the
  # order they will appear in the text (and in the order the replica numbers
  # them in the vector clock: seq0+1, seq0+2, ...).
  defp in_text_order(placed) do
    placed
    |> Enum.sort_by(fn {_posid, _ch, seq} -> seq end)
    |> Enum.map(fn {posid, ch, _seq} -> {posid, ch} end)
  end

  defp reject_dead(order, dead) do
    Enum.reject(order, fn {posid, _} -> MapSet.member?(dead, posid) end)
  end

  defp left_neighbour(_visibles, 0), do: []
  defp left_neighbour(visibles, i) do
    {posid, _} = Enum.at(visibles, i - 1)
    posid
  end

  defp right_neighbour([], _p), do: nil
  defp right_neighbour([{f, _} | _], []), do: f
  defp right_neighbour(order, p) do
    case Enum.drop_while(order, fn {q, _} -> q != p end) do
      [_, {f, _} | _] -> f
      _ -> nil
    end
  end
end
