defmodule Crdt.DiscoveryTest do
  use ExUnit.Case, async: false

  test "off by default, toggled with on/0 and off/0" do
    assert Process.whereis(Crdt.Discovery) == nil
    assert {:ok, pid} = Crdt.discovery_on()
    assert {:error, {:already_started, ^pid}} = Crdt.discovery_on()
    assert :ok = Crdt.discovery_off()
    assert Process.whereis(Crdt.Discovery) == nil
    assert :ok = Crdt.discovery_off()
  end
end
