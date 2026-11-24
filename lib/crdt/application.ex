defmodule Crdt.Application do
  @moduledoc false
  use Application

  @target Mix.target()

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Crdt.Supervisor]
    Supervisor.start_link(children(@target), opts)
  end

  defp children(:host) do
  # Host starts no children.
  # tests supervise their own Replica with a per-test history file.
  # An auto-started one would collide on the registered name Crdt.Replica.
    []
  end

  defp children(_target) do
    [
      {DynamicSupervisor, name: Crdt.DynSup, strategy: :one_for_one},
      Crdt.Boot
    ]
  end
end
