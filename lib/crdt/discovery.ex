defmodule Crdt.Discovery do
  @moduledoc """
  Peer discovery over the LAN.

  1. **Multicast announcement** — every 2 s, send a UDP packet with the tag
     `"crdt-treedoc-1 "` and our node name to group `233.252.1.32:45892`.
     Listen on the same group/port for peers.
  2. **/24 sweep** — every 10 s, ask each address's epmd which Erlang nodes it
     runs, and connect to the ones we don't know yet.  Catches peers whose
     multicast is blocked by the router.

  The multicast values (group, port, tag, interval, immediate first announce)
  are the wire contract — any node using the same tag and group finds us and
  vice versa.

  ## Robustness

  * The announced name is validated against a regex before it becomes an atom.
  * At most `@max_names` (256) announced names are kept.
  * A failed `Node.connect` is throttled for `@retry` (30 s) per peer.
  * Unknown packets are dropped silently.
  """

  use GenServer, restart: :temporary

  @group {233, 252, 1, 32}
  @port 45_892
  @tag "crdt-treedoc-1 "
  @announce_every 2_000

  @sweep_every 10_000
  @first_sweep 1_000
  @retry 30_000
  @max_names 256

  @name_regex ~r/\A[A-Za-z0-9_\-.]{1,64}@\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/

  @doc "Options: `:me`, `:ip`, `:port`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts discovery (off by default). Under `Crdt.DynSup` if it runs, else linked to the caller."
  def on do
    case Process.whereis(Crdt.DynSup) do
      nil -> start_link([])
      sup -> DynamicSupervisor.start_child(sup, {__MODULE__, []})
    end
  end

  @doc "Stops discovery and closes its socket. `:ok` even if it is not running."
  def off do
    if pid = Process.whereis(__MODULE__), do: GenServer.stop(pid)
    :ok
  end

  @doc "`{mode, names}` where mode is the listening state and names are heard peers."
  def info, do: GenServer.call(__MODULE__, :info)

  @doc "Build the announcement packet for `node`."
  def packet(node), do: @tag <> Atom.to_string(node)

  @doc "Parse an incoming packet; returns `{:ok, name}` or `:error`."
  def parse(@tag <> rest) when rest != "" do
    if Regex.match?(@name_regex, rest), do: {:ok, String.to_atom(rest)}, else: :error
  end

  def parse(_), do: :error

  @impl true
  def init(opts) do
    me = Keyword.get(opts, :me, node())
    port = Keyword.get(opts, :port, @port)
    ip = Keyword.get_lazy(opts, :ip, fn -> own_ip(me) end)

    :net_kernel.monitor_nodes(true)
    send(self(), :announce)
    Process.send_after(self(), :sweep, @first_sweep)

    {:ok,
     %{
       me: me,
       port: port,
       socket: open_socket(ip),
       ip: ip,
       failed: %{},
       sweeping: nil,
       names: MapSet.new()
     }}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, {describe_mode(state.socket, state.port), MapSet.to_list(state.names)}, state}
  end

  @impl true
  def handle_info(:announce, state) do
    Process.send_after(self(), :announce, @announce_every)
    state = reopen(state, own_ip(state.me))

    if state.socket != nil do
      :gen_udp.send(state.socket, @group, state.port, packet(state.me))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    case parse(data) do
      {:ok, name} -> {:noreply, announced(name, state)}
      :error -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_every)
    ip = own_ip(state.me)
    enabled = Application.get_env(:crdt, :sweep, true)

    if ip != nil and state.sweeping == nil and enabled do
      {:noreply, %{state | sweeping: Task.async(fn -> sweep(ip) end)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, _}, %{sweeping: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | sweeping: nil}}
  end

  @impl true
  def handle_info({:nodeup, n}, state) do
    say(state.me, "connected #{n}")
    {:noreply, state}
  end

  def handle_info({:nodedown, n}, state) do
    say(state.me, "disconnected #{n}")
    {:noreply, state}
  end

  def handle_info({:attempt, node, true}, state) do
    {:noreply, %{state | failed: Map.delete(state.failed, node)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp announced(name, state) do
    cond do
      MapSet.member?(state.names, name) ->
        attempt(name, state)

      MapSet.size(state.names) < @max_names ->
        attempt(name, %{state | names: MapSet.put(state.names, name)})

      true ->
        state
    end
  end

  defp attempt(node, state) do
    now = System.monotonic_time(:millisecond)

    if new_peer?(node) and Map.get(state.failed, node, now) <= now do
      me = self()
      spawn(fn -> send(me, {:attempt, node, Node.connect(node)}) end)
      %{state | failed: Map.put(state.failed, node, now + @retry)}
    else
      state
    end
  end

  defp new_peer?(node), do: node != node() and node not in Node.list()

  defp reopen(%{ip: ip} = state, ip), do: state

  defp reopen(state, ip) do
    if state.socket != nil, do: :gen_udp.close(state.socket)
    %{state | socket: open_socket(ip), ip: ip}
  end

  defp open_socket(nil), do: nil

  defp open_socket(ip) do
    opts = [
      :binary,
      active: true,
      reuseaddr: true,
      multicast_ttl: 1,
      multicast_loop: true,
      multicast_if: ip
    ]

    case :gen_udp.open(@port, opts ++ [add_membership: {@group, ip}]) do
      {:ok, socket} -> socket
      {:error, _} -> announce_only(opts)
    end
  end

  defp announce_only(opts) do
    case :gen_udp.open(0, opts) do
      {:ok, socket} -> socket
      {:error, _} -> nil
    end
  end

  defp describe_mode(nil, _), do: "announce only"
  defp describe_mode(_socket, port), do: "listening on #{port}"

  defp sweep(ip) do
    neighbours = neighbours(joined_ip(ip), prefix_of(ip))

    Task.async_stream(neighbours, &connect_at/1,
      max_concurrency: 64,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp connect_at(ip_str) do
    for node <- nodes_at(ip_str), new_peer?(node), do: Node.connect(node)
  end

  defp nodes_at(ip_str) do
    {:ok, ip} = :inet.parse_ipv4_address(String.to_charlist(ip_str))
    task = Task.async(fn -> :erl_epmd.names(ip) end)

    case Task.yield(task, 3_000) do
      {:ok, {:ok, names}} -> valid_names(names, ip_str)
      nil -> Task.shutdown(task, :brutal_kill); []
      _ -> []
    end
  end

  defp valid_names(names, ip_str) do
    for {name, _port} <- names, Regex.match?(@name_regex, "#{name}@#{ip_str}") do
      String.to_atom("#{name}@#{ip_str}")
    end
  end

  defp neighbours(joined, prefix) do
    [a, b, c, d] = String.split(joined, ".") |> Enum.map(&String.to_integer/1)
    size = Integer.pow(2, 32 - max(prefix, 24))
    base = d - rem(d, size)

    if size < 4 do
      []
    else
      for x <- (base + 1)..(base + size - 2), x != d do
        Enum.join([a, b, c, x], ".")
      end
    end
  end

  defp joined_ip(ip), do: Enum.join(Tuple.to_list(ip), ".")

  defp prefix_of(ip) do
    case :inet.getifaddrs() do
      {:ok, ifs} -> bits_in(netmask_of(ifs, ip))
      {:error, _} -> 24
    end
  end

  defp netmask_of(ifs, ip) do
    Enum.find_value(ifs, fn {_name, opts} ->
      if {:addr, ip} in opts, do: Keyword.get(opts, :netmask)
    end)
  end

  defp bits_in(nil), do: 24
  defp bits_in(mask), do: Enum.sum(Enum.map(Tuple.to_list(mask), &count_set_bits/1))

  defp count_set_bits(0), do: 0
  defp count_set_bits(byte), do: rem(byte, 2) + count_set_bits(div(byte, 2))

  defp own_ip(me) do
    if Node.alive?() do
      [_, host] = String.split(Atom.to_string(me), "@")
      to_ipv4(:inet.parse_ipv4_address(String.to_charlist(host)))
    else
      nil
    end
  end

  defp to_ipv4({:ok, {127, 0, 0, 1}}), do: nil
  defp to_ipv4({:ok, ip}), do: ip
  defp to_ipv4({:error, _}), do: nil

  defp say(me, text), do: IO.puts("[#{me}] #{text}")
end
