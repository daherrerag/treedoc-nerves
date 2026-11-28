defmodule Crdt.MessageTest do
  use ExUnit.Case, async: true

  alias Crdt.Message

  @ins %{op: :ins, from: :"doc@127.0.0.1", vc: %{:"doc@127.0.0.1" => 1}, pos: [{1, 1, :"doc@127.0.0.1"}], ch: "h"}
  @del %{op: :del, from: :b@x, vc: %{:"doc@127.0.0.1" => 1, :b@x => 1}, pos: [{1, 1, :"doc@127.0.0.1"}]}

  test "accepts valid ops and strips extra keys" do
    assert Message.validate(@ins) == {:ok, @ins}
    assert Message.validate(@del) == {:ok, @del}
    assert Message.validate(Map.put(@ins, :extra, 1)) == {:ok, @ins}
    assert {:ok, _} = Message.validate(%{@ins | ch: "é"})
  end

  test "rejects invalid shapes" do
    bad = [
      %{}, :garbage, Map.delete(@ins, :ch), %{@ins | op: :other},
      %{@ins | ch: "ab"}, %{@ins | ch: ""}, %{@ins | ch: <<255>>},
      %{@ins | from: "text"}, %{@ins | from: nil},
      %{@ins | vc: %{}}, %{@ins | vc: %{:"doc@127.0.0.1" => 0}},
      %{@ins | pos: []}, %{@ins | pos: [{2, 1, :a}]},
      %{@ins | pos: [{1, 0, :a}]}, %{@ins | pos: [{1, 1, "a"}]}
    ]

    for m <- bad, do: assert(Message.validate(m) == :error, inspect(m))
  end

  test "clock accepts atom => non_neg_integer maps only" do
    assert {:ok, %{a: 0, b: 3}} = Crdt.Message.clock(%{a: 0, b: 3})
    assert :error = Crdt.Message.clock(%{a: -1})
    assert :error = Crdt.Message.clock(%{"a" => 1})
    assert :error = Crdt.Message.clock("bad")
  end

  test "registered name is Crdt.Replica" do
    assert Message.name() == Crdt.Replica
  end
end
