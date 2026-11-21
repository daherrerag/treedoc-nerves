defmodule Crdt.Application do
  @moduledoc false
  use Application

  @target Mix.target()

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Crdt.Supervisor]
    Supervisor.start_link(children(@target), opts)
  end

  defp children(:host), do: []

  defp children(_target) do
    [
      {DynamicSupervisor, name: Crdt.DynSup, strategy: :one_for_one},
      Crdt.Boot
    ]
  end
end
