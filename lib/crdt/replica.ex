defmodule Crdt.Replica do
  @moduledoc """
  Owner of the node's state.

  Validates every incoming term with `Message.validate/1`.
  Causal delivery via `Causal`.  Forwards each applied op once.
  Unknown calls/casts/info are counted as `ignored`, never crash.
  """

  use GenServer

  alias Crdt.Causal
  alias Crdt.History
  alias Crdt.Message
  alias Crdt.Treedoc

  @max_buffer 50_000

  @doc """
  Starts the replica.

  ## Options

  * `:name`     — registered name (default `Crdt.Replica`).
  * `:log`      — explicit history file path.
  * `:data_dir` — fallback dir when `:log` is unset (default `data`).
  * `:me`       — node identity for the filename (default `node()`).

  History path: `:log` opt → `Application.get_env(:crdt, :log)` →
  `<:data_dir>/<short_name>.log` (`short_name` = `me` before `@`).
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, Message.name()))
  end

  @impl true
  def init(opts) do
    me = Keyword.get(opts, :me, node())
    path = history_path(opts, me)

    case History.open(path) do
      {:ok, fd} ->
        case History.load(path) do
          {:ok, ops} ->
            boot(me, path, fd, ops, false)

          {:corrupt, prefix, line} ->
            recover(me, path, fd, prefix, line)

          {:error, reason} ->
            say(me, "replica not started: cannot read #{path} (#{inspect(reason)})")
            :ignore
        end

      {:error, reason} ->
        say(me, "replica not started: cannot open #{path} (#{inspect(reason)})")
        :ignore
    end
  end

  defp boot(me, path, fd, ops, blocked) do
    :net_kernel.monitor_nodes(true)

    state = %{
      me: me,
      path: path,
      fd: fd,
      doc: Enum.reduce(ops, Treedoc.new(), &Treedoc.apply_op(&2, &1)),
      vc: rebuild_clock(ops),
      buffer: [],
      history: Enum.reverse(ops),
      n_history: length(ops),
      blocked: blocked,
      left: File.exists?(left_path(path)),
      received: 0,
      duplicates: 0,
      ignored: 0
    }

    if Node.list() != [], do: broadcast(state, {:hello, me, have(state.history)})
    {:ok, state}

  end

  # Rebuild the vector clock from the persisted history by max-merging every
  # op's clock.  This is more robust than `Causal.deliver/2` (which only bumps
  # `vc[from]`) because it picks up dependencies on other nodes even if their
  # ops are missing from this node's log — e.g. after a shelve that kept only
  # a prefix.
  defp rebuild_clock(ops) do
    Enum.reduce(ops, %{}, fn op, vc ->
      Enum.reduce(op.vc, vc, fn {k, n}, vc ->
        Map.put(vc, k, max(Map.get(vc, k, 0), n))
      end)
    end)
  end

  # Corrupted middle line: shelve the file (rename aside, rewrite the valid
  # prefix), and block local edits if we already have a node name — reusing it
  # would reissue sequence numbers the cluster has already seen.
  defp recover(me, path, fd, prefix, line) do
    :file.close(fd)

    case History.shelve(path, prefix) do
      {:ok, fd} ->
        say(me, "history damaged at line #{line}: kept #{length(prefix)} ops")
        blocked = Node.alive?()
        if blocked, do: say(me, "restart the node with another name to edit again")
        boot(me, path, fd, prefix, blocked)

      {:error, reason} ->
        say(me, "replica not started: cannot shelve #{path} (#{inspect(reason)})")
        :ignore
    end
  end

  defp history_path(opts, me) do
    cond do
      path = Keyword.get(opts, :log) -> path
      path = Application.get_env(:crdt, :log) -> path
      true ->
        data_dir = Application.get_env(:crdt, :data_dir, Keyword.get(opts, :data_dir, "data"))
        [name | _] = String.split(Atom.to_string(me), "@")
        Path.join(data_dir, name <> ".log")
    end
  end

  # ----------------------------------------------------------- local edits

  @impl true
  def handle_call({:insert, _i, _text}, _from, %{blocked: true} = state) do
    {:reply, {:error, :blocked}, state}
  end

  def handle_call({:insert, i, text}, _from, state) when is_binary(text) do
    if String.valid?(text) do
      insert_at(i, String.graphemes(text), state)
    else
      {:reply, {:error, :invalid_text}, state}
    end
  end

  def handle_call({:insert, _i, _text}, _from, state) do
    {:reply, {:error, :invalid_args}, state}
  end

  @impl true
  def handle_call({:delete, _i, _n}, _from, %{blocked: true} = state) do
    {:reply, {:error, :blocked}, state}
  end

  def handle_call({:delete, i, n}, _from, state) do
    case Treedoc.prepare_delete(state.doc, i, n) do
      {:ok, posids} -> delete(posids, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Atomic edit addressed by PosID: delete `del`, then insert `ins` right after
  # `anchor`.  One validate / persist / broadcast for the whole edit, so no
  # remote op can land between the delete and the insert, and a failure leaves
  # nothing applied.
  @impl true
  def handle_call({:edit, _edit}, _from, %{blocked: true} = state) do
    {:reply, {:error, :blocked}, state}
  end

  def handle_call({:edit, %{del: ids, anchor: anchor, ins: text}}, _from, state)
      when is_list(ids) and is_list(anchor) and is_binary(text) do
    if String.valid?(text) do
      edit(ids, anchor, String.graphemes(text), state)
    else
      {:reply, {:error, :invalid_text}, state}
    end
  end

  def handle_call({:edit, _edit}, _from, state) do
    {:reply, {:error, :invalid_args}, state}
  end

  # --------------------------------------------------------------- queries

  @impl true
  def handle_call(:text, _from, state), do: {:reply, Treedoc.text(state.doc), state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, Enum.reverse(state.history), state}
  end

  @impl true
  def handle_call(:debug, _from, state) do
    rows =
      for {posid, ch} <- Treedoc.ordered(state.doc) do
        {ch, posid, MapSet.member?(state.doc.dead, posid)}
      end

    {:reply, rows, state}
  end

  @impl true
  def handle_call(:leave, _from, state) do
    case File.write(left_path(state.path), "", [:sync]) do
      :ok -> {:reply, :ok, %{state | left: true}}
      {:error, reason} -> {:reply, {:error, {:disk, reason}}, state}
    end
  end

  @impl true
  def handle_call(:join, _from, %{left: false} = state), do: {:reply, :ok, state}
  # Resume: resend our history and ask peers for theirs (`:hello`).
  @impl true
  def handle_call(:join, _from, state) do
    case File.rm(left_path(state.path)) do
      ok when ok in [:ok, {:error, :enoent}] ->
        state = %{state | left: false}
        broadcast(state, {:hello, state.me, have(state.history)})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, {:disk, reason}}, state}
    end
  end

  @impl true
  def handle_call(_other, _from, state) do
    {:reply, {:error, :unknown}, state}
  end

  # ---------------------------------------------------------- remote ops

  @impl true
  def handle_cast({:remote, _raw}, %{left: true} = state),
    do: {:noreply, %{state | ignored: state.ignored + 1}}

  @impl true
  def handle_cast({:remote, raw}, state) do
    case Message.validate(raw) do
      {:ok, op} -> {:noreply, remote_op(op, state)}
      :error -> {:noreply, %{state | ignored: state.ignored + 1}}
    end
  end

  @impl true
  def handle_cast({:hello, node}, state) when is_atom(node) do
    send_history(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({tag, node, have}, state) when tag in [:hello, :have] and is_atom(node) do
    case Message.clock(have) do
      {:ok, have} ->
        send_missing(state, node, have)
        if tag == :hello, do: send_have(state, node)
        {:noreply, state}

      :error ->
        {:noreply, %{state | ignored: state.ignored + 1}}
    end
  end

  @impl true
  def handle_cast(_other, state) do
    {:noreply, %{state | ignored: state.ignored + 1}}
  end

  # ------------------------------------------------------------- network

  def handle_info({:nodeup, n}, state) do
    state = remember_name(state)
    send_have(state, n)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, n}, state) do
    say(state.me, "disconnected #{n}")
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state) do
    {:noreply, %{state | ignored: state.ignored + 1}}
  end

  # ----------------------------------------------------------- insert impl

  defp insert_at(i, chars, state) do
    case author(state, chars) do
      {:ok, me, state} -> do_insert(i, chars, me, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_insert(i, chars, me, state) do
    seq0 = Map.get(state.vc, me, 0)

    case Treedoc.prepare_insert(state.doc, i, chars, seq0, me) do
      {:ok, posids} -> local_ops(ins_ops(posids, seq0 + 1, me, state.vc), state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp ins_ops([], _seq, _me, _vc), do: []

  defp ins_ops([{posid, ch} | rest], seq, me, vc) do
    op = %{op: :ins, from: me, vc: Map.put(vc, me, seq), pos: posid, ch: ch}
    [op | ins_ops(rest, seq + 1, me, vc)]
  end

  # ------------------------------------------------------------- edit impl

  defp edit([], _anchor, [], state), do: {:reply, :ok, state}

  defp edit(ids, anchor, chars, state) do
    with {:ok, del_ids} <- Treedoc.prepare_delete_ids(state.doc, ids),
         {:ok, me, state} <- author(state, del_ids ++ chars) do
      do_edit(del_ids, anchor, chars, me, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Deletes take seqs seq0+1..seq0+k, the insert continues after them.  New
  # PosIDs are placed on the current doc; tombstones do not change the full
  # order, so it makes no difference that the deletes are not applied yet.
  defp do_edit(del_ids, anchor, chars, me, state) do
    seq0 = Map.get(state.vc, me, 0)
    dels = del_ops(del_ids, seq0 + 1, me, state.vc)
    seq1 = seq0 + length(dels)

    case prepare_ins(state.doc, anchor, chars, seq1, me) do
      {:ok, posids} -> local_ops(dels ++ ins_ops(posids, seq1 + 1, me, state.vc), state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A pure delete needs no anchor, so a stale one is not an error.
  defp prepare_ins(_doc, _anchor, [], _seq, _me), do: {:ok, []}
  defp prepare_ins(doc, anchor, chars, seq, me), do: Treedoc.prepare_insert_after(doc, anchor, chars, seq, me)

  # ----------------------------------------------------------- delete impl

  defp delete(posids, state) do
    case author(state, posids) do
      {:ok, me, state} ->
        local_ops(del_ops(posids, Map.get(state.vc, me, 0) + 1, me, state.vc), state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp del_ops([], _seq, _me, _vc), do: []

  defp del_ops([posid | rest], seq, me, vc) do
    op = %{op: :del, from: me, vc: Map.put(vc, me, seq), pos: posid}
    [op | del_ops(rest, seq + 1, me, vc)]
  end

  # The node name to attribute edits to.  Empty edit list needs no author.
  # Use `node()` if distributed (it may have changed after a `Node.stop`/
  # restart); otherwise reuse the remembered name, or refuse.
  defp author(state, []), do: {:ok, nil, state}

  defp author(state, _non_empty) do
    cond do
      Node.alive?() -> {:ok, node(), %{state | me: node()}}
      state.me != nil -> {:ok, state.me, state}
      true -> {:error, :no_network}
    end
  end

  # ----------------------------------------------- local apply pipeline

  # validate → persist → apply → broadcast.
  # Persist before broadcast (durable before peers see it);
  # validate before persist (log reloads cleanly).
  defp local_ops([], state), do: {:reply, :ok, state}

  defp local_ops(ops, state) do
    if Enum.all?(ops, &(Message.validate(&1) != :error)) do
      persist(ops, state)
    else
      {:reply, {:error, :invalid_op}, state}
    end
  end

  defp persist(ops, state) do
    case History.add(state.fd, ops) do
      :ok ->
        state =
          Enum.reduce(ops, state, fn op, s ->
            %{s | doc: Treedoc.apply_op(s.doc, op), vc: Causal.deliver(s.vc, op)}
          end)

        Enum.each(ops, &broadcast(state, {:remote, &1}))
        {:reply, :ok, note(state, ops)}

      {:error, reason} ->
        {:reply, {:error, {:disk, reason}}, state}
    end
  end

  # --------------------------------------------------------- remote apply

  defp remote_op(op, state) do
    {vc, buffer, applied, result} = Causal.receive(state.vc, state.buffer, op)
    state = %{state | vc: vc, buffer: trim(buffer)}

    state =
      case result do
        :duplicate -> %{state | duplicates: state.duplicates + 1}
        _ -> state
      end

    apply_remote(applied, state)
  end

  defp trim(buffer) do
    if length(buffer) > @max_buffer do
      Enum.drop(buffer, length(buffer) - @max_buffer)
    else
      buffer
    end
  end

  # Persist applied remote ops (one fsync), apply them, forward once each.
  defp apply_remote([], state), do: state

  defp apply_remote(ops, state) do
    case History.add(state.fd, ops) do
      :ok -> :ok
      {:error, reason} -> say(state.me, "cannot write #{state.path}: #{inspect(reason)}")
    end

    doc = Enum.reduce(ops, state.doc, &Treedoc.apply_op(&2, &1))

    Enum.each(ops, &broadcast(state, {:remote, &1}))

    %{state | doc: doc, received: state.received + length(ops)}
    |> note(ops)
  end

  defp note(state, ops) do
    %{state | history: Enum.reverse(ops, state.history), n_history: state.n_history + length(ops)}
  end

  # ------------------------------------------------------------- helpers

  @doc false
  # Highest seq per author among the applied ops.
  def have(history) do
    Enum.reduce(history, %{}, fn %{from: f, vc: vc}, acc ->
      Map.update(acc, f, vc[f], &max(&1, vc[f]))
    end)
  end

  @doc false
  # Ops (oldest first) that a peer with this `have` lacks.
  def missing(ops, have) do
    Enum.filter(ops, fn %{from: f, vc: vc} -> vc[f] > Map.get(have, f, 0) end)
  end

  defp send_history(state) do
    Enum.each(Enum.reverse(state.history), &broadcast(state, {:remote, &1}))
  end

  defp send_have(%{left: true}, _node), do: :ok
  defp send_have(state, node), do: to_peer(node, {:have, state.me, have(state.history)})

  defp send_missing(%{left: true}, _node, _have), do: :ok

  defp send_missing(state, node, have) do
    state.history |> Enum.reverse() |> missing(have) |> Enum.each(&to_peer(node, {:remote, &1}))
  end

  # Only connected nodes: a forged name must not make us dial out.
  defp to_peer(node, message) do
    if node in Node.list(), do: GenServer.cast({Message.name(), node}, message)
    :ok
  end

  # Left: nothing goes out.
  defp broadcast(%{left: true}, _message), do: :ok

  defp broadcast(_state, message) do
    for n <- Node.list(), do: GenServer.cast({Message.name(), n}, message)
  end

  defp left_path(path), do: path <> ".left"

  defp remember_name(state) do
    if Node.alive?(), do: %{state | me: node()}, else: state
  end

  defp status_map(state) do
    %{
      node: node(),
      author: state.me,
      peers: Node.list(),
      clock: state.vc,
      waiting: waiting_summary(state),
      history: state.n_history,
      chars: map_size(state.doc.chars),
      dead: MapSet.size(state.doc.dead),
      received: state.received,
      duplicates: state.duplicates,
      ignored: state.ignored,
      blocked: state.blocked,
      left: state.left,
      file: state.path
    }
  end

  defp waiting_summary(state) do
    Enum.map(state.buffer, fn op ->
      {op.from, op.vc[op.from], Causal.missing(state.vc, op)}
    end)
  end

  defp say(me, text), do: IO.puts("[#{me}] #{text}")
end
