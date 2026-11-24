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

  defp random_term do
    Enum.at(
      [:garbage, {:remote, %{}}, {:hello, "not_atom"}, %{},
       {:remote, op(:rand.uniform(5), "x")}, {:nodeup, :fake@node}],
      :rand.uniform(6) - 1
    )
  end
end
