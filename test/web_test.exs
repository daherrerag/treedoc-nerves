defmodule Crdt.WebTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:crdt, :log, Path.join(dir, "w.log"))
    on_exit(fn -> Application.delete_env(:crdt, :log) end)
    start_supervised!(Crdt.Replica)
    :ok
  end

  defp get_state, do: request(:get, "/state", nil)
  defp api(path), do: request(:get, path, nil)

  defp post_edit(del, after_id, ins),
    do: request(:post, "/edit", %{"del" => del, "after" => after_id, "ins" => ins})

  defp request(method, path, body) do
    conn =
      case body do
        nil -> conn(method, path)
        body -> method |> conn(path, Jason.encode!(body)) |> put_req_header("content-type", "application/json")
      end

    conn = Crdt.Web.call(conn, Crdt.Web.init([]))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp text(%{"chars" => chars}), do: Enum.map_join(chars, & &1["ch"])
  defp ids(%{"chars" => chars}), do: Enum.map(chars, & &1["id"])

  test "an empty document has no chars" do
    assert {200, %{"chars" => []}} = get_state()
  end

  test "edits are addressed by id and come back as the new snapshot" do
    assert {200, st} = post_edit([], [], "abc")
    assert text(st) == "abc"
    assert [[[_bit, _seq, node] | _] | _] = ids(st)
    assert is_binary(node)

    [a, b, _c] = ids(st)
    assert {200, st} = post_edit([b], a, "XY")
    assert text(st) == "aXYc"
    assert Crdt.text() == "aXYc"
  end

  test "an edit lands next to its anchor even if the document changed since the page looked" do
    {200, st} = post_edit([], [], "abc")
    [a, b, _c] = ids(st)

    # Someone else (a remote op, or IEx) edits before this page's next request.
    :ok = Crdt.insert(0, "Z")

    assert {200, st} = post_edit([b], a, "XY")
    assert text(st) == "ZaXYc"
  end

  test "bad ids or bodies change nothing" do
    {200, st} = post_edit([], [], "abc")
    [a | _] = ids(st)

    assert {422, %{"error" => "invalid id"} = st} = post_edit([[[1, 1, "no_such_atom_zq9x"]]], a, "")
    assert text(st) == "abc"
    assert {422, %{"error" => "invalid id"}} = post_edit([], [[2, 1, "x"]], "x")
    assert {422, %{"error" => ":unknown_anchor"}} = post_edit([], [[1, 99, "nonode@nohost"]], "x")
    assert {400, %{"error" => _}} = request(:post, "/edit", %{"nope" => 1})

    assert Crdt.text() == "abc"
  end

  describe "read-only views" do
    setup do
      {200, st} = post_edit([], [], "abc")
      [a, b, _c] = ids(st)
      {200, _} = post_edit([b], a, "XY")
      :ok
    end

    test "/api/status is the replica's status, with waiting ops as objects" do
      assert {200, %{"node" => _, "status" => st}} = api("/api/status")
      assert %{"history" => 6, "chars" => 5, "dead" => 1, "waiting" => [], "blocked" => false} = st
      assert is_map(st["clock"])
    end

    test "/api/doc is the visible text" do
      assert {200, %{"text" => "aXYc", "hash" => hash}} = api("/api/doc")
      assert hash == :erlang.phash2("aXYc")
    end

    test "/api/raw lists tombstones too, in full order, with PosIDs" do
      assert {200, %{"total" => 5, "rows" => rows}} = api("/api/raw")
      assert Enum.map_join(for(r <- rows, not r["dead"], do: r["ch"]), & &1) == "aXYc"
      assert [%{"ch" => "b", "id" => [[_, _, _] | _]}] = Enum.filter(rows, & &1["dead"])
    end

    test "/api/ops is the application log: who, which seq, what" do
      assert {200, %{"total" => 6, "ops" => ops}} = api("/api/ops")
      assert Enum.map(ops, & &1["op"]) == ["ins", "ins", "ins", "del", "ins", "ins"]
      assert Enum.map(ops, & &1["seq"]) == [1, 2, 3, 4, 5, 6]
      assert ops |> Enum.map(& &1["from"]) |> Enum.uniq() == [Atom.to_string(node())]
      assert [%{"ch" => nil} | _] = Enum.filter(ops, &(&1["op"] == "del"))
    end

    test "/api/peers with no peers is just this node" do
      assert {200, %{"self" => me, "rows" => [row], "discovery" => nil}} = api("/api/peers")
      assert %{"node" => ^me, "self" => true, "reachable" => true, "known" => true} = row
      assert %{"same_text" => true, "peer_lacks" => 0, "we_lack" => 0, "history" => 6} = row
    end

    test "?node= must be this node or a connected peer" do
      me = Atom.to_string(node())
      assert {200, %{"node" => ^me}} = api("/api/status?node=" <> me)
      assert {404, %{"error" => "unknown node"}} = api("/api/status?node=ghost@10.9.9.9")
      assert {404, _} = api("/api/raw?node=ghost@10.9.9.9")
    end
  end
end
