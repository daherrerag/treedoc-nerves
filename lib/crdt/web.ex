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
  """

  use Plug.Router

  @page_file Path.join(__DIR__, "web/index.html")
  @external_resource @page_file
  @page File.read!(@page_file)

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

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --------------------------------------------------------------- helpers

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
