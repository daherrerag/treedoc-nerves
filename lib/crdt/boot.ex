defmodule Crdt.Boot do
  use GenServer
  require Logger

  @name "doc"
  @iface "wlan0"
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
    node = :"#{@name}@#{:inet.ntoa(ip)}"

    case ensure_distribution(node) do
      :ok ->
        Node.set_cookie(@cookie)
        File.mkdir_p!(@data_dir)

        start_child({Crdt.Replica, [data_dir: @data_dir]})
        start_child({Crdt.Discovery, []})

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

    # Puertos del start.sh del repo original
    :application.set_env(:kernel, :inet_dist_listen_min, 4218)
    :application.set_env(:kernel, :inet_dist_listen_max, 4228)

    case Node.start(node, :longnames) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # El firmware no arranca epmd solo
  # No suelen haber problemas si epmd ya esta corriendo y este ejecuta
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

  # de start.sh
  #defp hostname do
  #  {:ok, host} = :inet.gethostname()

  #  host
  #  |> List.to_string()
  #  |> String.downcase()
  #  |> String.replace(~r/[^a-z0-9_-]/, "_")
  #end

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
