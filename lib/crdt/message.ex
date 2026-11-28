defmodule Crdt.Message do
  @moduledoc """
  Wire-message validator and the registered name of the Replica process.

      %{
        op:   :ins | :del,
        from: atom, # node name "doc@<ip>"
        vc:   %{atom => pos_integer}, # vector clock
        pos:  [{0|1, pos_integer, atom}, ...], # non-empty PosID path
        ch:   binary  # single grapheme
      }

  The map may carry extra keys — they are stripped on validation.
  Anything that does not match the shape is rejected as
  `:error` without raising.
  """

  @registered_name Crdt.Replica

  # Cap the vector clock size we accept, so a 10 000-entry clock from a
  # malicious or buggy peer is rejected without walking it.
  @max_vc 10_000

  @doc "The registered name of the Replica GenServer."
  def name, do: @registered_name

  @doc """
  Validate a raw term received from the network (or read from disk).

  Returns `{:ok, op}` — a cleaned map with exactly the keys the contract
  allows — or `:error`.  Never raises.
  """
  def validate(%{op: :ins, from: from, vc: vc, pos: pos, ch: ch}) do
    if base?(from, vc, pos) and grapheme?(ch) do
      {:ok, %{op: :ins, from: from, vc: vc, pos: pos, ch: ch}}
    else
      :error
    end
  end

  def validate(%{op: :del, from: from, vc: vc, pos: pos}) do
    if base?(from, vc, pos) do
      {:ok, %{op: :del, from: from, vc: vc, pos: pos}}
    else
      :error
    end
  end

  def validate(_), do: :error

  @doc "Validate the `have` map of `:hello` / `:have`: `%{atom => non_neg_integer}`."
  def clock(clock), do: if(vc?(clock), do: {:ok, clock}, else: :error)

  # A grapheme is a valid UTF-8 binary whose first grapheme is itself.
  defp grapheme?(ch) when is_binary(ch) do
    String.first(ch) == ch and String.valid?(ch)
  end

  defp grapheme?(_), do: false

  defp base?(from, vc, pos) do
    node?(from) and vc?(vc) and own_entry?(Map.get(vc, from)) and pos != [] and steps?(pos)
  end

  defp node?(from) do
    is_atom(from) and from not in [nil, true, false]
  end

  defp vc?(vc) when is_map(vc) and map_size(vc) <= @max_vc do
    Enum.all?(vc, fn {k, n} -> is_atom(k) and is_integer(n) and n >= 0 end)
  end

  defp vc?(_), do: false

  # The sender's own entry must be present and >= 1
  # an operation always advances its origin's clock.
  defp own_entry?(n) when is_integer(n) and n >= 1, do: true
  defp own_entry?(_), do: false

  defp steps?([]), do: true
  defp steps?([{bit, seq, node} | rest])
       when bit in [0, 1] and is_integer(seq) and seq >= 1 and is_atom(node) do
    steps?(rest)
  end
  defp steps?(_), do: false
end
