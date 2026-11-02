# CLI keep-running scope parity

The native lifecycle boundary now includes the ordered Compose argument plan for
`PITHEAD_KEEP_RUNNING`. The generated Bash CLI still owns service discovery,
running-service checks, locks, firewall preparation, Compose execution, retries,
recovery and operator output. The lifecycle verbs are not fully native.

## Native boundary

`go/internal/lifecycle/keep_running.go` drops exactly `--remove-orphans`, preserves
the order of remaining option arguments, excludes kept services and adds
`--no-deps` only when services remain. Its keep-list comparison uses the same
literal space-delimited substring test as Bash. Tabs, newlines, repeated spaces,
duplicates, empty service names and invalid UTF-8 bytes retain their original
behavior. An all-kept plan is empty and never becomes a whole-stack Compose up.

The Bash hook runs after the original discovery and running-service checks. It
sends the raw keep value, original arguments and captured ordered services through
a NUL-delimited helper protocol. Canonical counts, complete framing, the producer
status and helper status must all succeed before the global result is assigned.
Input is bounded to 1 MiB and 8192 combined argument/service items. Output may
contain 8193 arguments after adding `--no-deps`.

Unsupported inputs, missing helpers and malformed or failed replies retain the
reference planner. Unset, Bash and Python selectors ignore native helpers.
Go-selected CLI fallback carries the existing private hybrid state; no public
reference selector is repurposed.

## Oracle and supplementary evidence

Existing tests and fixtures remain unchanged. The additive harness sources the
original `tests/stack/lib.sh`, invokes its fixture builder and restores Go
selection after the harness scrubs operator variables. Each fragment must
contribute assertions; the surrounding safety checks do not become native merely
because Go selection is present.

Go selection, the current reference and the frozen starting checkout
`a73ffced33800de9435779a9cabef53864455acb` each pass these 309 assertions in the
disposable Linux ARM64 runner:

| Unchanged fragment | Assertions | Recorded scope-helper calls |
|---|---:|---:|
| `lifecycle/keep-running.sh` | 17 | 4 |
| `lifecycle/lock-core.sh` | 40 | 0 |
| `lifecycle/lock-wiring.sh` | 18 | 0 |
| `firewall/lan-guard.sh`, including its check fragment | 198 | 0 |
| `firewall/lan-guard-first-network.sh` | 36 | 0 |

These six source fragments, including the nested LAN check, are byte-identical
to the frozen starting checkout. No existing oracle or fixture was edited.

All four native calls return success, with no unexpected fallback. The additive
Linux driver passes three controls: normal native ownership, a forced-unsupported
source mutation and a wrong-plan source mutation. The unsupported mutation leaves
all 309 oracle assertions green and records four exit-125 statuses; running the
normal native-success guard against that same binary fails as required. The
empty-plan mutation records native success but breaks the unchanged oracle.
Native status is checked independently of the oracle verdict.

Ten added host comparisons cover native selection, strict success, both source
mutations, explicit unsupported or malformed-reply compatibility and the
three reference selectors. They run through
`make test-go-keep-running-scope-parity`, included in the bounded Go CI job.
Linux executes the full unchanged fragments; the fast host comparisons alone do
not establish lifecycle parity.

The first exploratory run omitted the fixture builder and stopped at an unbound
wallet variable; a frozen lock-holder precondition also failed in that attempt.
The fully initialized runs above pass without changing the original fixtures.

Go unit tests cover literal matching, option order, independent result copies,
arbitrary bytes, canonical framing, input/count bounds, reader errors, closed
writers and short writes. All-package race tests, vet and module verification
pass. Both commands cross-build for Linux amd64 and arm64 with CGO disabled.
GNU-first topology checks, including new files without exemptions, shell/Python/
YAML lint, scoped Markdown, documentation voice/paths, operator strings, file
budgets against the frozen base and generated CLI checks pass. Independent
correctness and security reviews pass.

The 12 added CLI comparisons and three-mode reference-selection sentinels pass.
Both unchanged redaction selftests pass with selection unset. The older lifecycle
option target initially failed its internal-marker fixture after the public
selector correction. Its Make target now uses a new launcher of the existing
private-marker adapter, preserving all ten methods. The default adapter target,
`make test-go-legacy-helper-parity`, still passes all 45 comparisons across five
groups. The original shared adapter, tests and fixtures remain unchanged.

Both reference and Go `make test` attempts pass shell/Python lint and stop at the
unchanged Markdown gate: 1382 errors in ignored dependency and frozen-source
caches, including the extra starting-checkout copy used for this round. Changed
project Markdown passes its scoped check. No gate, threshold or exemption was
changed; later targets do not run in those required-gate attempts.

## Remaining proof

The complete lifecycle matrix, privileged Linux/fleet behavior and production
artifacts remain pending. No host, daemon or live stack was changed. The runner
uses a read-only repository mount, disposable writable test storage and no Docker
socket or network. Python dashboard coverage and prior full-matrix results remain
recorded in [the revision-storage report](results-revision-store.md); this CLI
slice does not change dashboard application source.
