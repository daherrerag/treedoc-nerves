# Treedoc — collaborative text editor on Nerves

A Treedoc CRDT that runs on a Raspberry Pi (Nerves)
and syncs with peer nodes over a local network.
Strong Eventual Consistency via causal delivery and vector clocks.

## Architecture

```
Crdt.Application
  └── Crdt.DynSup (DynamicSupervisor)
        ├── Crdt.Boot        — waits for wlan0 IP, starts distribution
        ├── Crdt.Replica     — owns the document state (GenServer)
        └── Crdt.Discovery   — multicast + /24 epmd sweep

Crdt.Treedoc    — pure CRDT data type
Crdt.Causal     — vector-clock causal delivery
Crdt.Message    — wire-message validator + registered name
Crdt.History    — append-only durable log (CRC32-checked)
```

## IEx API

```elixir
Crdt.insert(0, "hello")     # insert text at index
Crdt.delete(0, 2)           # delete 2 chars at index
Crdt.text()                 # visible text
Crdt.status()               # summary map (clock, peers, counters)
Crdt.history()              # list of applied ops
Crdt.debug()                # each char with PosID and deleted? flag
```

## Build for the Pi

### Prerequisites

```sh
mise plugin install fwup https://github.com/fwup-home/asdf-fwup.git
mise use -g fwup@latest
mix archive.install hex nerves_bootstrap
```

### Set Wi-Fi credentials

```sh
export NERVES_WIFI_SSID="your-network"
export NERVES_WIFI_PSK="your-password"
```

### Compile and flash

```sh
# For Raspberry Pi 4:
export MIX_TARGET=rpi4
mix deps.get
mix firmware
mix firmware.burn    # insert SD card first
```

Supported targets: `rpi`, `rpi0`, `rpi0_2`, `rpi2`, `rpi3`, `rpi4`, `rpi5`,
`bbb`, `x86_64`, `qemu_aarch64`.

### SSH into the device

After boot, the device joins the Wi-Fi network and appears as
`nerves.local` (mDNS).  Connect:

```sh
ssh nerves.local
```

You'll get an IEx prompt.  The node starts automatically as `doc@<ip>` with
cookie `cpd2026`.

## Run from a laptop

To sync with a Pi (or another laptop) from your development machine:

### 1. Start an Erlang node with the same cookie

```sh
iex --sname laptop --cookie cpd2026 -S mix
```

Use `--sname` if both machines are on the same subnet and mDNS resolves.
Use `--name laptop@<your-ip>` with longnames if you need full IP routing:

```sh
iex --name laptop@192.168.1.10 --cookie cpd2026 -S mix
```

### 2. Connect to the Pi

```elixir
Node.connect(:"doc@192.168.1.50")
Node.list()    # should show [:"doc@192.168.1.50"]
```

The Pi's IP is shown in the serial console or `nerves.local` SSH session.
Once connected, the two nodes exchange history automatically.

### 3. Edit

```elixir
Crdt.insert(0, "hello from laptop")
Crdt.text()    # "hello from laptop"
```

The Pi sees the same text within seconds.  Edits from either node converge.

### 4. Run multiple laptop nodes

```sh
# Terminal 1
iex --sname alice --cookie cpd2026 -S mix

# Terminal 2
iex --sname bob --cookie cpd2026 -S mix
```

```elixir
# In alice's shell:
Node.connect(:"bob@<hostname>")
Crdt.insert(0, "hi bob")
```

```elixir
# In bob's shell:
Crdt.text()    # "hi bob"
```

## Web editor (browser view of a node)

```sh
iex --name laptop@192.168.1.10 --cookie cpd2026 -S mix
```

```elixir
Crdt.Web.start()                      # then open http://localhost:4000
Node.connect(:"doc@192.168.1.50")     # or Crdt.Web.start(discovery: true)
```

The page is a thin client: edits are sent as `{index, del, ins}` to the local
replica; remote edits show up via polling `/state`.  On a Pi, run
`Crdt.Web.start(ip: {0, 0, 0, 0})` from the SSH IEx to serve it at
`http://nerves.local:4000`.

## How peers find each other

1. **Multicast** — every node announces itself every 2 s on UDP group
   `233.252.1.32:45892` with the tag `"crdt-treedoc-1 "`.
2. **/24 sweep** — every 10 s, each node asks every IP in its /24 which
   Erlang nodes it runs (via epmd).  Catches peers when multicast is blocked.

On a laptop, the /24 sweep is off by default (so you don't probe someone
else's network).  Enable it with:

```sh
CRDT_SWEEP=on iex --sname laptop --cookie cpd2026 -S mix
```

## Wire contract

All nodes that use the same multicast tag + group + Erlang cookie are
interoperable.  Messages are plain Erlang terms sent via
`GenServer.cast({Crdt.Replica, node}, {:remote, op})` over distribution.

Each operation is:

```elixir
%{
  op:   :ins | :del,
  from: atom,                         # node name, e.g. :"doc@10.0.0.5"
  vc:   %{atom => pos_integer},       # vector clock
  pos:  [{0|1, pos_integer, atom}],   # PosID path (non-empty)
  ch:   binary                        # single grapheme (:ins only)
}
```

Validated by `Crdt.Message.validate/1` on every incoming term.

## Persistence

The history log lives at `/data/crdt/doc.log` on the Pi (one op per line,
`term_to_binary` + CRC32 + Base64).  One `fsync` per batch before any op is
applied or sent, so sequence numbers survive a crash.  On restart, the
document and vector clock are rebuilt from the log.

## Tests

```sh
mix test
```

Tests cover Treedoc convergence, causal delivery, message validation, history
round-trip and corruption recovery, and replica robustness against garbage
input.

## Paper

Nuno Preguiça, Joan Manuel Marquès, Marc Shapiro, Mihai Leția.
*A commutative replicated data type for cooperative editing.*
ICDCS 2009. <https://doi.org/10.1109/ICDCS.2009.20>

## Limitations

- Tombstones and history grow forever (no GC).
- The whole history is resent on each `:nodeup`.
- Typing char-by-char at the end makes the path one step longer per char
  (pastes are balanced).
