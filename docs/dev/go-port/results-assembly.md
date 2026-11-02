# Dashboard state assembly parity

Go selects the ordered top-level `/api/state` fields, section references, sync
gate, page title and manual window through the `state` helper. Python retains
provider calls and section callback execution in their original order. This
slice does not establish a fully native dashboard or poll loop.

## Native boundary

The helper receives only booleans, logical slot indices, stratum keys and window
references. Section results and raw provider objects stay in Python. The ordered
native response resolves those opaque references without traversing their values,
preserving object identity, non-JSON test doubles and native section results.
The helper never receives the raw history, worker fleet or complete state body.
Stratum names use the existing nonempty string-key contract; malformed helper
inputs fail closed.

The 48 fixed fields retain their order. Stratum expansion occurs after the onion
field, preserving the original dictionary's insertion position and last-value
behavior when keys collide. Window endpoints retain their supplied objects;
empty windows remain null. The original syncing value is retained separately
from its truth value used by the title. Tari-required and Monero-only flags
retain their short-circuit evaluation order.

Python still reads providers and settings, derives egress/topology values,
collects clocks, executes section callbacks and assembles the inputs. Existing
Go adapters continue to own the section policies recorded in their respective
results. The existing immutable bridge envelope, bounded chart transport and
concurrent poll coalescing remain in place. The normal native assembler uses an
application-owned pool of four workers,
with no queued admission beyond those four. Canceling a caller retains its slot
until the worker returns. A busy pool produces a sanitized state error; it does
not trigger reference fallback. Application cleanup waits for workers. An explicit
server-builder interposition retains its original synchronous call boundary.

Invalid native field lists, wrong key multiplicities, malformed title/gate/window
values, invalid references and helper failures raise without calling the Python
reference assembler. The shared channel requires a boolean success marker.
Public unset, Bash and Python selection keep the reference implementation;
only the Go dashboard child installs the adapter.

## Oracle and supplementary evidence

The additive assembly adapter makes the original `views.build_state` body fatal,
including the server alias, and records successful native calls, errors and
unexpected fallback attempts. It preserves a clone only for explicit paired
reference comparisons. The focused target runs all unchanged view suites and
the unchanged state API suite under `PITHEAD_IMPL=go`.

Four new paired comparisons check the complete payload, key order, stratum
collisions, sync/gate/title/window combinations, frozen inputs, callback order
and opaque object identity. Source-overlay mutations change the title and chart
mapping independently. The title control breaks an unchanged original test;
the chart control breaks the new opaque-result comparison. Three selection
sentinels prove the reference modes never launch the native assembler.

Fourteen runtime cases cover malformed replies, strict envelope markers,
event-loop behavior and cancellation. Four blocked workers retain their slots
after caller cancellation, a fifth is rejected, capacity returns on completion
and cleanup waits for a running worker. The existing 86400-row, four/twelve-client
regressions retain one bounded input/completion envelope per concurrent poll.
Go units cover
required fields, bounds, large slot counts, stratum expansion, windows, unknown
operations, unknown fields and trailing JSON. New tests supplement the original
oracle; no original test, fixture or threshold changes.

The focused target passes 432 tests: 407 unchanged originals, 23 new assembly
cases and two existing large-history comparisons. It records 63 native assembly
calls, zero native errors and zero unexpected fallbacks. The same 407 originals
also pass on the frozen starting checkout. Worker counters are aggregated for
the full dashboard run under xdist. The earlier port-added snapshot-interleaving
test calls the private bridge without application startup; an additive fixture
supplies the application-owned executor and closes it afterward. Its original
test body and assertions remain unchanged. This is setup compatibility, not a
reference fallback.

The frozen starting oracle remains
`a73ffced33800de9435779a9cabef53864455acb`.

## Commands and results

```bash
make test-go-dashboard-assembly-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Go race tests, vet and module verification cover the
whole module. Both commands cross-build for Linux amd64 and arm64 with CGO
disabled. The bounded CI job includes the focused target.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 81.44%; total gate passes |
| Go selection with storage/native-body adapters | 3815 passed | 78.55%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.55%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three additions from
earlier rounds. The Go matrix adds 96 native boundary cases without running
paired reference comparisons. Its aggregated assembly counters record 28 native
calls, zero errors and zero unexpected fallbacks. Combined coverage includes
retained Python reference paths; it does not make the Go-only total gate pass.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 272 missing of 2408 changed lines; fails | 93%; 155 missing of 2408; passes |
| Frozen starting comparison | 91%; 166 missing of 2067 changed lines; passes | 92%; 151 missing of 2067; passes |

The diff gates omit the new untracked assembly and executor modules until the
operator commits them. Both XML datasets independently measure 134 of 136
assembly statements and 16 of 19 executor statements. The patch gates must run
again after that commit. Existing comparison bases and thresholds are unchanged.

Python/YAML lint, documentation voice and path checks, operator strings,
GNU-first topology checks, file budgets and generated CLI checks pass. The
topology scan includes new files without exemptions. Changed Markdown passes
the repository rules separately. File-budget checks use the documented frozen
starting override; default-base differences remain recorded in [PARITY](PARITY.md).
Independent correctness and security reviews pass on this boundary.

Both reference and Go `make test` attempts stop at the unchanged Markdown gate
on third-party files in local dependency caches. Neither reaches later targets;
the dashboard matrices above run separately. The full required gate remains red.
No existing check or threshold was weakened.

The dashboard image already copies the complete backend package. Image,
appliance and fleet proof for this working-tree slice remain pending. Checks
use locked Python 3.11, Go 1.27.1, UTC and worktree-local offline caches. Benchmark
files and live stacks are unchanged. Provider I/O, settings derivation and poll
orchestration remain Python.
