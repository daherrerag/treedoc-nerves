defmodule Crdt.HistoryTest do
  use ExUnit.Case, async: true

  alias Crdt.History

  @moduletag :tmp_dir

  defp op(seq, ch), do: %{op: :ins, from: :x, vc: %{x: seq}, pos: [{1, seq, :x}], ch: ch}

  test "round-trip", %{tmp_dir: dir} do
    file = Path.join(dir, "h.log")
    {:ok, fd} = History.open(file)
    ops = [op(1, "h"), op(2, "i")]
    :ok = History.add(fd, ops)
    :file.close(fd)
    assert {:ok, ^ops} = History.load(file)
  end

  test "missing file loads empty" do
    assert History.load("/nonexistent/path.log") == {:ok, []}
  end

  test "garbage line is corruption, prefix is kept", %{tmp_dir: dir} do
    file = Path.join(dir, "c.log")
    {:ok, fd} = History.open(file)
    :ok = History.add(fd, [op(1, "h")])
    :file.close(fd)
    File.write!(file, "GARBAGE\n", [:append])
    expected = [op(1, "h")]
    assert {:corrupt, ^expected, 2} = History.load(file)
  end

  test "shelve moves the bad file aside", %{tmp_dir: dir} do
    file = Path.join(dir, "s.log")
    {:ok, fd} = History.open(file)
    :ok = History.add(fd, [op(1, "a"), op(2, "b")])
    :file.close(fd)

    prefix = [op(1, "a")]
    {:ok, fd2} = History.shelve(file, prefix)
    :file.close(fd2)

    assert {:ok, ^prefix} = History.load(file)
    assert [_] = Path.wildcard(file <> ".damaged-*")
  end
end
