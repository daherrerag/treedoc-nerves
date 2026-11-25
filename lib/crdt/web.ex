defmodule Crdt.Web do
  @moduledoc """
  Tiny local web editor for a `Crdt.Replica`.

  The browser is a *thin client*: it holds no CRDT state.  `/state` gives it
  the visible chars as `{id, ch}` (the id is the PosID), and it sends edits as
  `{del: [ids], after: id, ins: text}`, addressed by PosID, not by index.  So
  an edit lands next to the chars the user was looking at even if remote ops
  arrived since.  `Crdt.edit/1` applies the delete and the insert as one
  atomic edit: persisted, then broadcast, exactly as `Crdt.insert/2` and
  `Crdt.delete/2` do from IEx.  The page polls `/state` to show edits that
  arrive from other nodes.

      iex --name laptop@192.168.1.10 --cookie cpd2026 -S mix
      iex> Crdt.Web.start()
      # open http://localhost:4000

  Routes: `GET /` page, `GET /state` snapshot, `POST /edit` apply an edit
  (200 and the new snapshot, or 422 and the snapshot plus `error`).

  Read-only views for the page's State, Nodes and Raw tabs.  All take an
  optional `?node=<name>` (this node or a connected peer, default this node)
  and use only the replica's existing calls, asked through its registered name:
  `GET /api/status`, `/api/doc`, `/api/raw`, `/api/ops`, and `GET /api/peers`
  (this node plus every peer: clock, lag, whether the texts match).
  """

  use Plug.Router

  @page_file Path.join(__DIR__, "web/index.html")
  @external_resource @page_file
  @page File.read!(@page_file)

  @ask_timeout 2_000
  @max_rows 5_000
  @max_ops 100

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  @doc """
  Starts the web server (and, on a laptop, a Replica if none is running).

  Options: `:port` (4000), `:ip` (`{127, 0, 0, 1}`; use `{0, 0, 0, 0}` to
  reach it from another machine), `:data_dir` ("data"), `:discovery` (false;
  start `Crdt.Discovery` so peers are found automatically).
  """
  def start(opts \\ []) do
    unless Node.alive?() do
      raise "distribution is off: start with `iex --name me@<ip> --cookie cpd2026 -S mix`"
    end

    with :ok <- ensure_replica(opts),
         :ok <- ensure_discovery(opts) do
      Bandit.start_link(
        plug: __MODULE__,
        scheme: :http,
        ip: Keyword.get(opts, :ip, {127, 0, 0, 1}),
        port: Keyword.get(opts, :port, 4000)
      )
    end
  end

  # On a Pi, Crdt.Boot already started the replica; on a laptop we start it.
  defp ensure_replica(opts) do
    if Process.whereis(Crdt.Replica) do
      :ok
    else
      [short | _] = String.split(Atom.to_string(node()), "@")
      log = Path.join(Keyword.get(opts, :data_dir, "data"), short <> ".log")

      case Crdt.Replica.start_link(log: log) do
        {:ok, _pid} -> :ok
        other -> {:error, {:replica, other}}
      end
    end
  end

  defp ensure_discovery(opts) do
    if Keyword.get(opts, :discovery, false) and Process.whereis(Crdt.Discovery) == nil do
      case Crdt.Discovery.start_link([]) do
        {:ok, _pid} -> :ok
        other -> {:error, {:discovery, other}}
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------- routes

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, @page)
  end

  get "/state" do
    send_json(conn, 200, snapshot())
  end

  post "/edit" do
    with %{"del" => ids, "after" => anchor, "ins" => text} when is_list(ids) and is_binary(text) <-
           conn.body_params,
         {:ok, del} <- decode_posids(ids),
         {:ok, anchor} <- decode_posid(anchor),
         :ok <- Crdt.edit(%{del: del, anchor: anchor, ins: text}) do
      send_json(conn, 200, snapshot())
    else
      {:error, reason} -> send_json(conn, 422, Map.put(snapshot(), :error, inspect(reason)))
      :error -> send_json(conn, 422, Map.put(snapshot(), :error, "invalid id"))
      _ -> send_json(conn, 400, %{error: "expected {del, after, ins}"})
    end
  end

  # ------------------------------------------------------- read-only views

  get "/api/status" do
    with_node(conn, fn conn, n ->
      case ask(n, :status) do
        %{} = st -> send_json(conn, 200, %{node: n, status: status_json(st)})
        other -> unavailable(conn, other)
      end
    end)
  end

  get "/api/doc" do
    with_node(conn, fn conn, n ->
      case ask(n, :text) do
        text when is_binary(text) ->
          send_json(conn, 200, %{node: n, text: text, hash: :erlang.phash2(text)})

        other ->
          unavailable(conn, other)
      end
    end)
  end

  # Every entry in full order, tombstones included: what `Crdt.debug/0` shows.
  get "/api/raw" do
    with_node(conn, fn conn, n ->
      case ask(n, :debug) do
        rows when is_list(rows) ->
          shown = for {ch, posid, dead} <- Enum.take(rows, @max_rows),
                      do: %{ch: ch, id: encode_posid(posid), dead: dead}

          send_json(conn, 200, %{node: n, total: length(rows), rows: shown})

        other ->
          unavailable(conn, other)
      end
    end)
  end

  # The last applied ops, oldest first: who authored what, in application order.
  get "/api/ops" do
    with_node(conn, fn conn, n ->
      case ask(n, :history) do
        ops when is_list(ops) ->
          last = for %{op: _, from: _, vc: _, pos: _} = op <- Enum.take(ops, -@max_ops), do: op_json(op)
          send_json(conn, 200, %{node: n, total: length(ops), ops: last})

        other ->
          unavailable(conn, other)
      end
    end)
  end

  # This node plus every connected peer, from each one's own `:status` and `:text`.
  get "/api/peers" do
    case {ask(node(), :status), ask(node(), :text)} do
      {%{clock: clock}, text} when is_map(clock) and is_binary(text) ->
        mine = %{clock: clock, hash: :erlang.phash2(text)}
        nodes = [node() | Node.list()]
        send_json(conn, 200, %{self: node(), rows: peer_rows(nodes, mine), discovery: discovery()})

      other ->
        unavailable(conn, other)
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --------------------------------------------------------------- helpers

  # `?node=` must name this node or a connected peer.  It is compared as a
  # string against that list, so no atom is ever created from the request.
  defp with_node(conn, fun) do
    conn = fetch_query_params(conn)
    known = [node() | Node.list()]

    case conn.query_params["node"] do
      nil -> fun.(conn, node())
      "" -> fun.(conn, node())
      name ->
        case Enum.find(known, &(Atom.to_string(&1) == name)) do
          nil -> send_json(conn, 404, %{error: "unknown node"})
          n -> fun.(conn, n)
        end
    end
  end

  # Call a node's replica by its registered name.  Another implementation, or
  # a replica that is not running, answers with something that is not a map.
  defp ask(node, request) do
    GenServer.call({Crdt.Message.name(), node}, request, @ask_timeout)
  catch
    :exit, _ -> {:error, :unreachable}
  end

  defp unavailable(conn, other), do: send_json(conn, 502, %{error: inspect(other)})

  # `waiting` is a list of `{from, seq, missing}` tuples, which JSON cannot hold.
  defp status_json(st) do
    waiting =
      for {from, seq, missing} <- Map.get(st, :waiting, []),
          do: %{from: from, seq: seq, missing: missing}

    Map.put(st, :waiting, waiting)
  end

  defp op_json(%{op: op, from: from, vc: vc, pos: pos} = o) do
    %{op: Atom.to_string(op), from: from, seq: vc[from], id: encode_posid(pos), ch: Map.get(o, :ch)}
  end

  defp peer_rows(nodes, mine) do
    nodes
    |> Task.async_stream(&peer_row(&1, mine), timeout: @ask_timeout * 2, on_timeout: :kill_task)
    |> Enum.zip(nodes)
    |> Enum.map(fn
      {{:ok, row}, _n} -> row
      {_exit, n} -> %{node: n, self: n == node(), reachable: false}
    end)
  end

  defp peer_row(n, mine) do
    base = %{node: n, self: n == node()}

    case {ask(n, :status), ask(n, :text)} do
      {%{clock: clock} = st, text} when is_map(clock) and is_binary(text) ->
        Map.merge(base, %{
          reachable: true,
          known: true,
          clock: clock,
          history: Map.get(st, :history),
          waiting: length(Map.get(st, :waiting, [])),
          received: Map.get(st, :received),
          duplicates: Map.get(st, :duplicates),
          ignored: Map.get(st, :ignored),
          same_text: :erlang.phash2(text) == mine.hash,
          peer_lacks: lack(mine.clock, clock),
          we_lack: lack(clock, mine.clock)
        })

      {{:error, :unreachable}, _} ->
        Map.put(base, :reachable, false)

      _other_implementation ->
        Map.merge(base, %{reachable: true, known: false})
    end
  end

  # How many ops `a` has applied that `b` has not (sum over authors).
  defp lack(a, b) do
    Enum.reduce(a, 0, fn {k, n}, acc -> acc + max(0, n - Map.get(b, k, 0)) end)
  end

  defp discovery do
    if Process.whereis(Crdt.Discovery) do
      {mode, heard} = Crdt.Discovery.info()
      %{mode: mode, heard: heard}
    end
  catch
    :exit, _ -> nil
  end

  # PosID <-> JSON: [[bit, seq, "node"], ...].  Ids come from the browser, so
  # node names are only turned into *existing* atoms (never creates one).
  defp encode_posid(posid) do
    Enum.map(posid, fn {bit, seq, node} -> [bit, seq, Atom.to_string(node)] end)
  end

  defp decode_posids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case decode_posid(id) do
        {:ok, posid} -> {:cont, {:ok, [posid | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp decode_posid(steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, []}, fn
      [bit, seq, node], {:ok, acc}
      when bit in [0, 1] and is_integer(seq) and seq >= 1 and is_binary(node) ->
        case existing_atom(node) do
          {:ok, atom} -> {:cont, {:ok, [{bit, seq, atom} | acc]}}
          :error -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp decode_posid(_), do: :error

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  # One `debug` call gives text and ids from the same moment: the visible
  # chars in order, each with its PosID.
  defp snapshot do
    with %{} = st <- Crdt.status(),
         rows when is_list(rows) <- Crdt.debug() do
      %{
        chars: for({ch, posid, false} <- rows, do: %{id: encode_posid(posid), ch: ch}),
        node: node(),
        author: st.author,
        peers: st.peers,
        clock: st.clock,
        history: st.history,
        waiting: length(st.waiting),
        blocked: st.blocked
      }
    else
      _ -> %{error: "replica not running"}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
