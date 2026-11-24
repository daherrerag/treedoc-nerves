defmodule Crdt.CausalTest do
  use ExUnit.Case, async: true

  alias Crdt.Causal

  defp op(from, vc), do: %{op: :del, from: from, vc: vc, pos: [{1, 1, from}]}

  test "next_local bumps the own entry by one" do
    assert Causal.next_local(%{}, :a) == {1, %{a: 1}}
    assert Causal.next_local(%{a: 3, b: 2}, :a) == {4, %{a: 4, b: 2}}
  end

  test "classify: duplicate, deliverable, waiting" do
    vc = %{a: 2, b: 1}

    assert Causal.classify(vc, op(:a, %{a: 2})) == :duplicate
    assert Causal.classify(vc, op(:a, %{a: 3, b: 1})) == :deliverable
    assert Causal.classify(vc, op(:a, %{a: 4})) == :waiting
    assert Causal.classify(vc, op(:a, %{a: 3, b: 2})) == :waiting
    assert Causal.classify(vc, op(:c, %{c: 1, a: 2})) == :deliverable
  end

  test "buffer drains in causal order when the missing op arrives" do
    a1 = op(:a, %{a: 1})
    a2 = op(:a, %{a: 2})
    b1 = op(:b, %{a: 2, b: 1})

    {vc, buffer, [], :waiting} = Causal.receive(%{}, [], b1)
    {vc, buffer, [], :waiting} = Causal.receive(vc, buffer, a2)
    {vc, buffer, [], :waiting} = Causal.receive(vc, buffer, a2)
    assert length(buffer) == 2
    assert Causal.missing(vc, b1) == %{a: 2}

    {vc, buffer, applied, :applied} = Causal.receive(vc, buffer, a1)
    assert applied == [a1, a2, b1]
    assert buffer == []
    assert vc == %{a: 2, b: 1}
    assert {^vc, [], [], :duplicate} = Causal.receive(vc, [], a2)
  end
end
