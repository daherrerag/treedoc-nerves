defmodule Crdt.Boot do
  @moduledoc """
  Waits for `wlan0` to get an IPv4 from VintageNet, then:

  1. Starts `epmd -daemon`.
  2. Sets the distribution port range to `4218..4228`.
  3. Starts the node in longnames mode as `doc@<ip>`.
  4. Sets the magic cookie to `:cpd2026`.
  5. Starts `Crdt.Replica` under `Crdt.DynSup`.  `Crdt.Discovery` stays off until `Crdt.discovery_on/0`.
  """

  use GenServer
  require Logger

  @iface "wlan0"
  @short_name "doc"
  @cookie :cpd2026
  @data_dir "/data/crdt"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    VintageNet.subscribe(["interface", @iface, "connection"])
    VintageNet.subscribe(["interface", @iface, "addresses"])
    {:ok, %{started?: false}, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, maybe_start(state)}

  @impl true
  def handle_info({VintageNet, ["interface", @iface, _property], _old, _new, _meta}, state),
    do: {:noreply, maybe_start(state)}

  def handle_info(:retry, state), do: {:noreply, maybe_start(state)}
  def handle_info(_other, state), do: {:noreply, state}

  defp maybe_start(%{started?: true} = state), do: state

  defp maybe_start(state) do
    case ipv4() do
      nil -> state
      ip -> start_everything(ip, state)
    end
  end

  defp start_everything(ip, state) do
    node = :"#{@short_name}@#{:inet.ntoa(ip)}"

    case ensure_distribution(node) do
      :ok ->
        Node.set_cookie(@cookie)
        File.mkdir_p!(@data_dir)

        start_child({Crdt.Replica, [data_dir: @data_dir]})

        Logger.info("crdt node #{node} started")
        %{state | started?: true}

      {:error, reason} ->
        Logger.error("Node.start(#{node}) failed: #{inspect(reason)}; retrying in 2 s")
        Process.send_after(self(), :retry, 2_000)
        state
    end
  end

  defp ensure_distribution(node) do
    start_epmd()

    :application.set_env(:kernel, :inet_dist_listen_min, 4218)
    :application.set_env(:kernel, :inet_dist_listen_max, 4228)

    case Node.start(node, :longnames) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_epmd do
    case System.cmd("epmd", ["-daemon"], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> Logger.warning("epmd exited with #{code}: #{out}")
    end
  rescue
    error in ErlangError -> Logger.error("cannot run epmd: #{inspect(error)}")
  end

  defp start_child(spec) do
    case DynamicSupervisor.start_child(Crdt.DynSup, spec) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> Logger.warning("#{inspect(spec)} did not start: #{inspect(other)}")
    end
  end

  # First non-link-local IPv4 on @iface.
  defp ipv4 do
    case VintageNet.get(["interface", @iface, "addresses"]) do
      [_ | _] = addrs ->
        Enum.find_value(addrs, fn
          %{family: :inet, address: {169, 254, _, _}} -> nil
          %{family: :inet, address: {_, _, _, _} = ip} -> ip
          _ -> nil
        end)

      _ ->
        nil
    end
  end
end
