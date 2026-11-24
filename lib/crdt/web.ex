defmodule Crdt.Web do
  @moduledoc """
  Tiny local web editor for a `Crdt.Replica`.

  The browser is a thin client.
  It diffs the textarea against the last text the replica confirmed
  POSTs `{index, del, ins}`.
  The replica turns that into Treedoc ops, persists, and broadcasts,
  as `Crdt.insert/2` and `Crdt.delete/2` do from IEx.

  The page polls `/state` to show edits that arrive from other nodes.

      iex --name laptop@192.168.1.10 --cookie cpd2026 -S mix
      iex> Crdt.Web.start()
      # open http://localhost:4000

  Routes: `GET /` page, `GET /state` snapshot, `POST /edit` apply an edit.
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

  # Routes
  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, @page)
  end

  get "/state" do
    send_json(conn, 200, snapshot())
  end

  post "/edit" do
    case conn.body_params do
      %{"index" => i, "del" => d, "ins" => s}
      when is_integer(i) and is_integer(d) and is_binary(s) ->
        with :ok <- Crdt.delete(i, d),
             :ok <- insert(i, s) do
          send_json(conn, 200, snapshot())
        else
          {:error, reason} ->
            send_json(conn, 422, Map.put(snapshot(), :error, inspect(reason)))
        end

      _ ->
        send_json(conn, 400, %{error: "expected {index, del, ins}"})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # helpers

  defp insert(_i, ""), do: :ok
  defp insert(i, text), do: Crdt.insert(i, text)

  defp snapshot do
    with %{} = st <- Crdt.status(),
         text when is_binary(text) <- Crdt.text() do
      %{
        text: text,
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
