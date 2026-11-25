defmodule Crdt do
  @moduledoc """
  Collaborative text editor over Treedoc, with no central server.

  IEx API.  All calls go to the `Crdt.Replica` GenServer (registered as
  `Crdt.Replica`).
  """

  alias Crdt.Replica

  @doc "Inserts each character of `text` starting at `index`."
  def insert(index, text) when is_binary(text), do: call({:insert, index, text})

  @doc "Deletes `count` characters starting at `index` (default 1)."
  def delete(index, count \\ 1), do: call({:delete, index, count})

  @doc """
  Atomic edit addressed by PosID instead of index.

  Deletes the chars in `:del` (PosIDs), then inserts `:ins` right after the
  char `:anchor` (`[]` = start).  Both are optional.  Returns `:ok`, or
  `{:error, reason}` with nothing applied.  PosIDs come from `debug/0`.

      Crdt.edit(%{del: [posid_of_b], anchor: posid_of_a, ins: "XY"})
  """
  def edit(%{} = edit), do: call({:edit, Map.merge(%{del: [], anchor: [], ins: ""}, edit)})
  def edit(_), do: {:error, :invalid_args}

  @doc "Visible text of this node's copy."
  def text, do: call(:text)

  @doc "Summary map: node, peers, clock, waiting, counters, etc."
  def status, do: call(:status)

  @doc "List of applied ops in application order (newest last)."
  def history, do: call(:history)

  @doc "Each char with its PosID and deleted? flag, as `{ch, pos, dead?}`."
  def debug, do: call(:debug)

  # 60 s timeout.  On no-replica or exit, returns a tuple instead of crashing.
  defp call(request) do
    GenServer.call(Replica, request, 60_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :no_replica}
  end
end
