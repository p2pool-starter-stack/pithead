# Telemetry capture parity

Go owns the hourly disk/network capture decision, the worker capture cadence,
falsy value normalization and online-worker row shaping. Python retains the
clock, async poll loop, database callbacks, timestamp assignments and every
other collector phase. This slice adds no probes.

## Native boundary

The poll loop takes its existing clock reading once and passes it to shared
capture orchestration. Four fleet operations implement hourly planning, network
values, the scalar worker gate and the batched worker rows. No operation reads a
clock, network endpoint or database.

Hourly captures retain the inclusive wall-clock gate and disk-then-network write
order. Network inputs are read after the awaited disk write. The hourly stamp
advances after both writes. The worker gate and interval are read after those
awaits, so callback changes remain observable in the same phase as the reference.
Worker rows retain online-only filtering, names, falsy-to-zero values and field
order. One callback receives the complete batch; an empty due batch still
advances the worker stamp. Failed callbacks retain the original successful-write
prefix and leave the affected stamp unchanged.

The scalar worker gate runs before reading or projecting the worker collection.
A poll that is not due never sends worker rows through the helper. A due capture
uses four native calls at most, independent of fleet size. During review the
initial implementation was corrected to avoid serializing the full worker feed
on every poll. The added not-due regression uses a collection that raises on
iteration; it verifies scalar-only transport and no write.

Python projects only the fields used by each phase. Opaque extra fields and
worker credentials do not enter this telemetry request. Replies require exact
plan fields, Boolean gates, fixed-width value lists and at most one row per input worker,
with the captured timestamp. Validation precedes the corresponding write. Native
failures propagate without selecting the reference planner. Arbitrary Python-only
mapping subclasses, iterators and opaque values inside consumed telemetry fields
are outside the JSON service boundary.

The reference planner is extracted from the original inline block. Both modes
share async orchestration and retain the original clock binding and interval
constants. Unset, Bash and Python selection keep the reference planner.

## Oracle and supplementary evidence

The additive plugin makes the extracted reference planner body fatal under Go
selection. Paired comparisons alone expose its clone. Counters distinguish native
completions, structured errors and unexpected reference calls, including reports
from xdist workers.

The focused target passes 57 tests: 14 unchanged originals and 43 additive cases.
The originals cover telemetry backbone hooks, aggregation and poll synchronization.
The same 14 originals pass on the frozen starting checkout and current Python
reference. The frozen oracle remains
`a73ffced33800de9435779a9cabef53864455acb`; original tests, fixtures and thresholds
are unchanged.

The additions cover threshold equality, backward clocks, malformed records,
falsy inputs, sparse names, offline filtering, callback failures, malformed native
plans and forced mutations between awaited writes. A 1000-worker capture proves
one native request per phase. Go units cover a 20000-worker batch, immutability
and numeric/error boundaries. A source mutation reverses the hourly gate and
fails the unchanged first-poll oracle. Three fake-binary sentinels prove that
unset, Bash and Python selection never invoke native telemetry.

Focused counters record 36 hourly, 22 network, 24 worker-gate and 18 worker-row
completions. Deliberately malformed records raise two hourly, two network and one
worker `AttributeError`. There are zero unexpected reference calls. Mutation,
worker-process and selection subprocesses are separate controls.

## Commands and results

```bash
make test-go-dashboard-telemetry-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both commands cross-build for Linux amd64 and arm64 with
CGO disabled. The focused target is included in the bounded Go CI workflow.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 79.9983%; displays 80.00% and prints a coverage failure |
| Go selection with storage/native-body adapters | 3877 passed | 78.15%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.40%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three earlier additions.
The Go matrix adds 158 native boundary cases without paired reference comparisons.
Worker-aggregated telemetry counters record 140 hourly, 73 network, 132 worker-gate
and 70 worker-row completions, with no errors or unexpected reference calls.
The Go dataset covers 34 of the shared capture module's 51 executable statements;
the union covers 48. Reference policy remains deliberately unexecuted under Go.

Reference coverage was exactly 80.00% before this slice. It now falls fractionally
below that gate. The reference command returns zero while its coverage report
prints failure; this is not recorded as a passing coverage gate. Neither the
threshold nor its implementation changed.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 322 missing of 2806 changed lines; fails | 93%; 188 missing of 2806; passes |
| Frozen starting comparison | 91%; 216 missing of 2465 changed lines; passes | 92%; 184 missing of 2465; passes |

The patch gates include the now-committed editor adapter and omit the new
untracked telemetry capture module until the operator commits it. Both XML
datasets measure that module; run patch coverage again after the commit. Bases
and thresholds are unchanged.

Python/YAML lint, scoped Markdown checks, documentation voice and path checks,
operator strings, GNU-first topology checks, file budgets and generated CLI
checks pass. Topology includes new files without exemptions. File budgets use the
documented frozen-start override; default-base differences remain in
[PARITY](PARITY.md). Independent correctness and security re-reviews pass after
the worker-gate transport correction.

Both reference and Go `make test` attempts stop at the unchanged Markdown gate on
third-party files in local dependency caches. Later targets do not run in those
attempts; the dashboard matrices above run separately. The full required gate
remains red. No existing test, check or threshold was weakened.

The dashboard image copies the complete backend package. Image, appliance and
fleet proof for this working-tree slice remain pending. Checks use locked Python
3.11, Go 1.27.1, UTC and worktree-local offline caches. No benchmark file, live
stack, existing check or threshold changed.
