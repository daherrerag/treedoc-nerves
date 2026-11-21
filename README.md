# Collaborative text editor with Treedoc

## Quick start

Manage with mise look at mise.toml for elixir erlang versions.

``` sh
mise plugin install fwup https://github.com/fwup-home/asdf-fwup.git`
mise use -g fwup@latest
```

For nerves dependencies look at 
https://nerves.hexdocs.pm/getting-started.html#introduction

Install nerves bootstrap

``` sh
mix archive.install hex nerves_bootstrap
```

Create a biolerplate

``` sh
mix nerves.new <proj-name>
```

If you use the start.sh from [original repo](https://github.com/fepecas/treedoc)
you can:

```elixir
Crdt.insert(index, "text")   # insert each character starting at index
Crdt.delete(index, count)    # delete count characters (count defaults to 1)
Crdt.text()                  # visible text
Crdt.status()                # node, table, discovery, connected nodes, clock, history, buffer
Crdt.history()               # last 10 applied operations; Crdt.history(:all) for all
Crdt.debug()                 # each character with its position identifier
```

## Without nerves

Look at original repo: https://github.com/fepecas/treedoc/tree/main

## Paper

Nuno Preguiça, Joan Manuel Marquès, Marc Shapiro, Mihai Leția.
*A commutative replicated data type for cooperative editing.*
ICDCS 2009. <https://doi.org/10.1109/ICDCS.2009.20>

## Known limitations 

(short texts, tombstones kept forever, discovery only
on the local network and more; a tombstone is a deleted character that is kept, hidden, with
its position):
[DESIGN.md, section 14](docs/DESIGN.md#14-known-limitations).
