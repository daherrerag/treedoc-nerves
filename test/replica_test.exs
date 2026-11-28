defmodule Crdt.ReplicaTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Crdt.History

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    file = Path.join(dir, "r.log")
    Application.put_env(:crdt, :log, file)
    on_exit(fn -> Application.delete_env(:crdt, :log) end)
  end

  defp op(seq, ch), do: %{op: :ins, from: :x, vc: %{x: seq}, pos: [{1, seq, :x}], ch: ch}

  test "garbage never crashes the replica" do
    pid = start_supervised!(Crdt.Replica)

    assert GenServer.call(Crdt.Replica, :whatever) == {:error, :unknown}

    for _ <- 1..500 do
      m = random_term()
      GenServer.cast(Crdt.Replica, m)
      send(Crdt.Replica, m)
    end

    assert Process.whereis(Crdt.Replica) == pid
    assert Crdt.status().ignored > 0
  end

  test "applies causally-ordered ops even out of order" do
    start_supervised!(Crdt.Replica)

    GenServer.cast(Crdt.Replica, {:remote, op(2, "o")})
    assert Crdt.text() == ""
    assert [{:x, 2, %{x: 1}}] = Crdt.status().waiting

    GenServer.cast(Crdt.Replica, {:remote, op(1, "h")})
    GenServer.cast(Crdt.Replica, {:remote, op(1, "h")})
    assert Crdt.text() == "ho"
    assert Crdt.status().waiting == []
    assert Crdt.status().duplicates == 1
  end

  test "leave ignores remote ops, survives a restart, and join resumes" do
    start_supervised!(Crdt.Replica)
    GenServer.cast(Crdt.Replica, {:remote, op(1, "h")})
    assert Crdt.text() == "h"

    assert :ok = Crdt.join()
    refute Crdt.status().left

    assert :ok = Crdt.leave()
    assert Crdt.status().left

    GenServer.cast(Crdt.Replica, {:remote, op(2, "i")})
    assert Crdt.text() == "h"
    assert Crdt.status().ignored == 1

    stop_supervised!(Crdt.Replica)
    start_supervised!(Crdt.Replica)
    assert Crdt.status().left
    assert Crdt.text() == "h"

    assert :ok = Crdt.join()
    refute Crdt.status().left
    GenServer.cast(Crdt.Replica, {:remote, op(2, "i")})
    assert Crdt.text() == "hi"
  end

  test "restart rebuilds from the log" do
    start_supervised!(Crdt.Replica)
    GenServer.cast(Crdt.Replica, {:remote, op(1, "h")})
    GenServer.cast(Crdt.Replica, {:remote, op(2, "i")})
    assert Crdt.text() == "hi"

    stop_supervised!(Crdt.Replica)
    start_supervised!(Crdt.Replica)

    assert Crdt.text() == "hi"
    assert Crdt.status().clock == %{x: 2}
  end

  test "corrupted log keeps the valid prefix", %{tmp_dir: dir} do
    file = Path.join(dir, "r.log")
    {:ok, fd} = History.open(file)
    :ok = History.add(fd, [op(1, "h")])
    :file.close(fd)
    File.write!(file, "garbage\n", [:append])
    {:ok, fd2} = History.open(file)
    :ok = History.add(fd2, [op(2, "i")])
    :file.close(fd2)

    output = capture_io(fn -> start_supervised!(Crdt.Replica) end)
    assert output =~ "damaged"
    assert Crdt.text() == "h"
  end

  defp visible_posids, do: for({_ch, p, false} <- Crdt.debug(), do: p)

  describe "edit/1 (anchored, atomic)" do
    test "deletes then inserts in one go, with consecutive sequence numbers" do
      start_supervised!(Crdt.Replica)
      :ok = Crdt.insert(0, "hello")
      [h, e, l1, l2, o] = visible_posids()
      n = length(Crdt.history())

      assert Crdt.edit(%{del: [e, l1, l2], anchor: h, ins: "ipp"}) == :ok
      assert Crdt.text() == "hippo"
      assert o in visible_posids()

      new_ops = Enum.drop(Crdt.history(), n)
      assert Enum.map(new_ops, & &1.op) == [:del, :del, :del, :ins, :ins, :ins]
      # "hello" used seqs 1..5; the edit continues with 6..8 (deletes) and 9..11 (inserts).
      assert Enum.map(new_ops, fn op -> op.vc[op.from] end) == Enum.to_list(6..11)
    end

    test "survives the log: a restart rebuilds the edited text" do
      start_supervised!(Crdt.Replica)
      :ok = Crdt.insert(0, "abc")
      [a, b, _c] = visible_posids()
      :ok = Crdt.edit(%{del: [b], anchor: a, ins: "XY"})
      assert Crdt.text() == "aXYc"

      stop_supervised!(Crdt.Replica)
      start_supervised!(Crdt.Replica)
      assert Crdt.text() == "aXYc"
    end

    test "a stale view still works: dead anchor, already-deleted ids" do
      start_supervised!(Crdt.Replica)
      :ok = Crdt.insert(0, "abc")
      [_a, b, _c] = visible_posids()
      :ok = Crdt.delete(1, 1)
      n = length(Crdt.history())

      assert Crdt.edit(%{anchor: b, ins: "Y"}) == :ok
      assert Crdt.text() == "aYc"

      n = n + 1
      assert Crdt.edit(%{del: [b], anchor: [], ins: ""}) == :ok
      assert length(Crdt.history()) == n
    end

    test "errors apply nothing" do
      start_supervised!(Crdt.Replica)
      :ok = Crdt.insert(0, "abc")
      [a, _b, _c] = visible_posids()
      n = length(Crdt.history())
      ghost = [{1, 99, :zz}]

      assert Crdt.edit(%{del: [a], anchor: ghost, ins: "x"}) == {:error, :unknown_anchor}
      assert Crdt.edit(%{del: [ghost], anchor: [], ins: "x"}) == {:error, :unknown_id}
      assert Crdt.edit(%{ins: <<255>>}) == {:error, :invalid_text}
      assert Crdt.edit(%{del: :nope}) == {:error, :invalid_args}
      assert Crdt.edit(:nope) == {:error, :invalid_args}

      assert Crdt.text() == "abc"
      assert length(Crdt.history()) == n
    end

    test "an empty edit is a no-op" do
      start_supervised!(Crdt.Replica)
      assert Crdt.edit(%{}) == :ok
      assert Crdt.history() == []
    end

  test "have/1 and missing/2" do
    ops = [op(1, "a"), op(2, "b")]
    assert Crdt.Replica.have(ops) == %{x: 2}
    assert Crdt.Replica.missing(ops, %{}) == ops
    assert Crdt.Replica.missing(ops, %{x: 1}) == [op(2, "b")]
    assert Crdt.Replica.missing(ops, %{x: 2}) == []
    end

  end

  defp random_term do
    Enum.at(
      [:garbage, {:remote, %{}}, {:hello, "not_atom"}, %{},
       {:remote, op(:rand.uniform(5), "x")}, {:nodeup, :fake@node}],
      :rand.uniform(6) - 1
    )
  end
end
