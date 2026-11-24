defmodule Crdt.Causal do
  @moduledoc """
  Causal delivery with vector clocks.

  * duplicate: `m[from] <= vc[from]` (already applied).
  * deliverable: `m[from] == vc[from] + 1` AND `m[k] <= vc[k]` for every
    other `k` (every dependency already delivered).
  * waiting: otherwise (buffer it).

  An op is identified by `{from, m[from]}`.
  The buffer keeps at most one copy per identity.
  """

  @doc "Next `{seq, vc}` for a local op at `me` (caller keeps vc only on success)."
  def next_local(vc, me) do
    seq = Map.get(vc, me, 0) + 1
    {seq, Map.put(vc, me, seq)}
  end

  @doc "Classify `op` against `vc` as `:duplicate`, `:deliverable` or `:waiting`."
  def classify(vc, %{from: i, vc: m}) do
    mi = Map.get(m, i, 0)
    vi = Map.get(vc, i, 0)

    cond do
      mi <= vi -> :duplicate
      mi == vi + 1 and deps_ready?(vc, i, m) -> :deliverable
      true -> :waiting
    end
  end

  @doc "Update `vc` as if `op` had been delivered: `vc[from] := m[from]`."
  def deliver(vc, %{from: i, vc: m}), do: Map.put(vc, i, Map.get(m, i, 0))

  @doc """
  Apply causal delivery to one incoming `op`.
  Returns
  `{vc, buffer, applied_ops, result}` where `applied_ops` is the op itself
  plus anything drained from the buffer that became deliverable, in delivery
  order, and `result` is `:applied | :duplicate | :waiting`.
  """
  def receive(vc, buffer, op) do
    case classify(vc, op) do
      :duplicate ->
        {vc, buffer, [], :duplicate}

      :waiting ->
        {vc, buffer_put(buffer, op), [], :waiting}

      :deliverable ->
        {vc, buffer, applied} = drain(deliver(vc, op), buffer, [op])
        {vc, buffer, applied, :applied}
    end
  end

  @doc "What `op` is still missing, as `%{node => needed_seq}`."
  def missing(vc, %{from: i, vc: m}) do
    Enum.reduce(m, %{}, fn {k, n}, acc ->
      need = if k == i, do: n - 1, else: n

      if need > Map.get(vc, k, 0) do
        Map.put(acc, k, need)
      else
        acc
      end
    end)
  end

  defp deps_ready?(vc, i, m) do
    Enum.all?(m, fn {k, n} -> k == i or n <= Map.get(vc, k, 0) end)
  end

  defp buffer_put(buffer, op) do
    if Enum.any?(buffer, &same_op?(&1, op)) do
      buffer
    else
      buffer ++ [op]
    end
  end

  # Drop duplicates from the buffer, then deliver the first deliverable op and
  # recurse.  Returns `{vc, buffer, applied_in_order}`.
  defp drain(vc, buffer, applied) do
    buffer = Enum.reject(buffer, fn op -> classify(vc, op) == :duplicate end)

    case Enum.find(buffer, fn op -> classify(vc, op) == :deliverable end) do
      nil ->
        {vc, buffer, Enum.reverse(applied)}

      op ->
        drain(deliver(vc, op), List.delete(buffer, op), [op | applied])
    end
  end

  defp same_op?(a, b), do: a.from == b.from and a.vc[a.from] == b.vc[b.from]
end
