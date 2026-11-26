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
        └── Crdt.Discovery   — multicast + /24 epmd sweep (off by default, started on demand)

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
Crdt.discovery_on()
Crdt.discovery_off()
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
iex --name laptop@192.168.1.10 --cookie cpd2026 \
  --erl "-kernel inet_dist_listen_min 4218 inet_dist_listen_max 4228 prevent_overlapping_partitions false" \
  -S mix
```

Always use `--name <name>@<your-ip>` (long names).  The Pi starts its node
with long names, and a short-name (`--sname`) node cannot connect to a
long-name one.  The `--erl` flags:

- `inet_dist_listen_min/max` pin the distribution ports to the same
  4218..4228 range the Pi uses, so one firewall rule covers both.
- `prevent_overlapping_partitions false` stops OTP from cutting a node's other
  links when one link drops (nothing here uses `:global`, so it buys nothing).
  The Pi release already sets it in `rel/vm.args.eex`.

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
iex --name alice@192.168.1.10 --cookie cpd2026 -S mix

# Terminal 2
iex --name bob@192.168.1.10 --cookie cpd2026 -S mix
```

```elixir
# In alice's shell:
Node.connect(:"bob@192.168.1.10")
Crdt.insert(0, "hi bob")
```

```elixir
# In bob's shell:
Crdt.text()    # "hi bob"
```

## Web editor (browser view of a node)

```sh
iex --name laptop@192.168.1.10 --cookie cpd2026 \
  --erl "-kernel prevent_overlapping_partitions false" -S mix
```

```elixir
Crdt.Web.start()                      # then open http://localhost:4000
Node.connect(:"doc@192.168.1.50")     # or Crdt.Web.start(discovery: true)
```

`Crdt.Web.start/1` starts a replica on the laptop (log in `data/<name>.log`)
if none is running.  On a Pi the replica already runs; from the SSH IEx use
`Crdt.Web.start(ip: {0, 0, 0, 0})` and open `http://nerves.local:4000`.  It
listens on 127.0.0.1 by default.

The page has four tabs and a node selector:

- **Document** — the visible text (`Crdt.text/0`), editable for this node.
- **State** — this node's CRDT state: author, peers, ops, chars, tombstones,
  counters, log file, vector clock, and the ops waiting for dependencies.
- **Nodes** — each connected node's clock, how many ops it lacks or we lack,
  whether its text matches ours, the discovery state, and the last ops applied
  here with their authors.
- **Raw** — every entry of the Treedoc in order, tombstones included, with
  its PosID path (`bit·seq·node`), depth, author and seq, plus the op log.

Peers are read-only: pick one in the selector to see its text, state and raw
document.  They are asked through the registered `Crdt.Replica` with the same
calls as `Crdt.status/0`, so a peer running another implementation shows as
"other implementation (no status)".

The page is a thin client.  It holds no CRDT state: it gets the visible chars
with their PosIDs from `/state` and sends each edit as
`{del: [ids], after: id, ins: text}` to `POST /edit`, which calls
`Crdt.edit/1`.  Because edits are addressed by PosID, not by index, they land
next to the chars you were looking at even if remote ops arrived meanwhile, and
the delete and insert of one edit are applied, persisted and broadcast
together.  Text typed while a request is in flight is replayed on top of the
reply.  If the server is unreachable the page retries with a backoff (0.8 s up
to 5 s) and keeps your unsent edits.

In IEx, `Crdt.edit(%{del: [posid], anchor: posid, ins: "text"})` does the same;
PosIDs come from `Crdt.debug/0`.

## How peers find each other

Discovery is **off by default**.  Start it from IEx with `Crdt.discovery_on()`
and stop it with `Crdt.discovery_off()`.

Otherwise connect nodes by hand with
`Node.connect/1`.

1. **Multicast** — every node announces itself every 2 s on UDP group
   `233.252.1.32:45892` with the tag `"crdt-treedoc-1 "`.
2. **/24 sweep** — every 10 s, each node asks every IP in its /24 which
   Erlang nodes it runs (via epmd).  Catches peers when multicast is blocked.

On a laptop, the /24 sweep is off by default (so you don't probe someone
else's network).  Enable it with:

```sh
CRDT_SWEEP=on iex --name laptop@192.168.1.10 --cookie cpd2026 -S mix
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

What other implementations need to share with this one is exactly this:
insert and delete ops with the same shape and PosID placement rule, causal
delivery with vector clocks (duplicates dropped), forwarding of applied ops,
the `{:hello, node}` catch-up, and `{seq, node}` never repeating.  The web
editor's extra calls (`:status`, `:text`, `:debug`, `:history`, `:edit`) are
local to this implementation and change nothing on the wire.

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
- A node name must never be reused once its log is gone.  A reflashed Pi, a
  wiped `/data`, or a deleted `data/<name>.log` restarts numbering at 1 under
  the same name, so peers drop its new ops as duplicates and the replicas
  diverge for good.  Use a different name (or IP) after losing a log.
- Web editor: it polls (about every 400 ms), and if you type over the very
  chars a remote edit changed at the same moment, the remote version wins for
  that spot.  The Nodes view only knows peers that answer the same calls.
