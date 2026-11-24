defmodule Crdt.History do
  @moduledoc """
  Append-only, one-operation-per-line history log.

  Each line is self-checking: a CRC32 of the binary term guards against a
  flipped byte that still decodes into a *different* valid operation (which
  would silently corrupt the clock).  A line that fails the check, or that
  `binary_to_term` rejects, counts as corrupted and stops the load — the valid
  prefix is kept, the rest is moved aside, and numbering continues from there.

  Uses `:raw` file mode (no Erlang I/O server) for speed on the Pi's SD card.
  """

  alias Crdt.Message

  @doc """
  Opens `path` for appending.  Creates the parent directory, truncates a
  trailing incomplete line (no terminator), and returns `{:ok, fd}` or
  `{:error, reason}`.
  """
  def open(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- cut_incomplete_line(path) do
      :file.open(path, [:append, :binary, :raw])
    end
  end

  @doc "Reads every line of `path` and returns `{:ok, ops}`, `{:corrupt, prefix_ops, line}`, or `{:error, reason}`."
  def load(path) do
    case File.read(path) do
      {:ok, data} -> read_lines(String.split(data, "\n", trim: true), 1, [])
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Appends `ops` with one `fsync`.  Returns `:ok` or `{:error, reason}`."
  def add(_fd, []), do: :ok

  def add(fd, ops) do
    lines = Enum.map(ops, fn op -> [encode(op), ?\n] end)

    with :ok <- :file.write(fd, lines) do
      :file.sync(fd)
    end
  end

  @doc """
  Recovery: renames the current log to `<path>.damaged-<timestamp>`, opens a
  fresh one, writes the valid `prefix_ops` back, and returns `{:ok, fd}`.
  """
  def shelve(path, prefix_ops) do
    with :ok <- File.rename(path, "#{path}.damaged-#{System.os_time(:second)}"),
         {:ok, fd} <- open(path),
         :ok <- add(fd, prefix_ops) do
      {:ok, fd}
    end
  end

  defp encode(op) do
    bin = :erlang.term_to_binary(op)
    Base.encode64(<<:erlang.crc32(bin)::32, bin::binary>>)
  end

  defp decode(line) do
    case Base.decode64(line) do
      {:ok, <<crc::32, bin::binary>>} -> verify(crc, bin)
      _ -> :error
    end
  end

  defp verify(crc, bin) do
    if :erlang.crc32(bin) == crc do
      Message.validate(:erlang.binary_to_term(bin))
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp read_lines([], _n, ops), do: {:ok, Enum.reverse(ops)}

  defp read_lines([line | rest], n, ops) do
    case decode(line) do
      {:ok, op} -> read_lines(rest, n + 1, [op | ops])
      :error -> {:corrupt, Enum.reverse(ops), n}
    end
  end

  defp cut_incomplete_line(path) do
    case File.read(path) do
      {:ok, data} -> maybe_truncate(path, data)
      {:error, _} -> :ok
    end
  end

  defp maybe_truncate(path, data) do
    if data == "" or String.ends_with?(data, "\n") do
      :ok
    else
      truncate(path, after_last_newline(data))
    end
  end

  defp after_last_newline(data) do
    case :binary.matches(data, "\n") do
      [] -> 0
      jumps ->
        {pos, _} = List.last(jumps)
        pos + 1
    end
  end

  defp truncate(path, pos) do
    with {:ok, f} <- :file.open(path, [:read, :write, :binary, :raw]),
         {:ok, _} <- :file.position(f, pos),
         :ok <- :file.truncate(f),
         :ok <- :file.sync(f) do
      :file.close(f)
    end
  end
end
