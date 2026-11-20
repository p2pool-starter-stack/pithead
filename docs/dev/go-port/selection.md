# Per-piece implementation selection (#4214)

The generated `pithead` is the installed entry point. At startup it decides, per
verb, whether the Go launcher or the Bash reference implementation runs. Every
piece of the Go port (pithead#3811) flips to Go in its own release through this
table, so a release never flips a whole binary at once.

## The table

The piece, its default, and the release that flipped it, in this order:

| piece | default | flipped in |
| --- | --- | --- |
| `help` | `bash` | - |
| `status` | `bash` | - |
| `payout-keys` | `bash` | - |
| `config-document` | `bash` | - |
| `caddy-render` | `bash` | - |
| `env-render` | `bash` | - |
| `doctor` | `bash` | - |

A tier-1 test fails when this table and
`_pithead_impl_table` in `lib/pithead/00a-impl-launcher.sh` disagree. Flipping
a piece means changing its row here and its default in the table together.

## The verb-to-piece map

Only these top-level verbs have an owning piece. A verb with no piece always
runs the Bash reference implementation. Each row is one verb and its piece:

- `help` -> `help`
- `-h` -> `help`
- `--help` -> `help`
- `version` -> `help`
- `-V` -> `help`
- `--version` -> `help`
- `status` -> `status`
- `doctor` -> `doctor`

A piece without any top-level verb —
`payout-keys`, `config-document`, `caddy-render`, `env-render` — is selected
by the Bash implementation itself with `_pithead_impl_selected <piece>` when it
reaches that layer.

A tier-1 test fails when this map and `_pithead_impl_verb_map` in
`lib/pithead/00a-impl-launcher.sh` disagree.

## Choosing a mode

The mode for a verb resolves in this order:

1. `PITHEAD_IMPL` from the environment.
1. A persistent selection file: `/etc/pithead-impl`, or `PITHEAD_IMPL_FILE`
   where set. The file must hold exactly one `PITHEAD_IMPL=<selection>` line.
1. The table default.

`PITHEAD_IMPL` holds a comma-separated list of piece names, or `bash`. An
explicit list selects Go for exactly the listed pieces and Bash for everything
else; `bash` forces Bash for all pieces. An unknown piece name fails loudly and
runs nothing — including the old whole-binary value `go`, which is not a piece
name. A selection file that is a symlink, owned by neither root nor the
invoking user, writable beyond its owner, unreadable, or malformed fails
loudly the same way.

Timers, path units, and `sudo` drop the environment, so they resolve through
the persistent file and the table default. An operator pinning units without
the file can instead drop in `Environment=PITHEAD_IMPL=bash` on the pithead
units.

## Go-side contract

When a verb resolves to Go, the launcher execs `$PITHEAD_GO_BINARY` when set,
otherwise `go/bin/pithead` beside the entry point, with the same argv, streams,
and descriptors, and exports `PITHEAD_GO_REFERENCE` as the fixed entry-point
path (`PITHEAD_SELF`).

- A missing or not-regular-file Go binary is not an error: the launcher
  continues with the Bash reference implementation, same argv, streams, and
  exit status. Neither is a Go binary `exec` cannot start (bad interpreter,
  wrong architecture): the launcher clears `PITHEAD_GO_REFERENCE` and
  `PITHEAD_IMPL_LAUNCHED` again and continues in Bash.
- Before execing the Go side the launcher exports `PITHEAD_IMPL_LAUNCHED=1`,
  and a launcher that already sees it never execs Go again, so a hand-back
  that forgets `PITHEAD_IMPL=bash` cannot loop.
- For any argv the Go side does not own, it must `exec bash` with
  `PITHEAD_GO_REFERENCE` (the fixed entry-point path), the original argv, the
  original streams and descriptors, and `PITHEAD_IMPL=bash` in the environment.
  `bash` forces Bash for every piece, so the re-entered launcher runs in place
  and the handoff cannot recurse.
- A Go-side failure of a verb it owns is that verb's failure; the launcher does
  not replay it in Bash.

The Bash suites stay green in both modes: `tests/stack/lib.sh` scrubs every
`PITHEAD_*` variable from the operator environment, so a sourced suite always
starts from the table default and only the launcher honors a selection.
