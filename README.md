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
