# Dashboard control-outcome parity

Go selects terminal current-control and control-history outcomes from bounded
metadata. Python retains worker reconciliation, revision-drift callbacks,
database calls, cap admission, audit writes and their interleaved await order.
This slice adds no host or network probes.

## Native boundary

`control-outcomes` accepts at most 256 rows and a terminal vocabulary of at most
64 strings, each at most 256 UTF-8 bytes, under the existing 2 MiB request limit.
Each row carries only identifier type/nonempty flags and status kind/value.
Identifiers, reasons, worker names and unrelated report fields stay in Python.
The reply is an ordered Boolean list, including an empty list for an empty batch.
Malformed input, oversized metadata and invalid replies fail explicitly.

The adapter returns the original identifier, status and reason objects. History
remains lazy, keeps the first-twenty-row boundary and preserves duplicates.
Reconciliation continues to suppress a history identifier matching the current
control only at its original point, after each history outcome is yielded.

Each reconciliation invocation owns a temporary metadata-plan scope. Bounded
lookahead batches future safe shapes without running callbacks or consuming
custom iterables. A cached verdict is reused only after the actual current fields
and vocabulary produce the same metadata key. Changes made by drift/database
callbacks therefore select a different plan. The scope is reset on exceptions
and cancellation. Current/history LRUs each retain at most 512 plans. Each batch
examines at most 4096 candidates, counting malformed and empty histories, and
lookahead follows the current history limit without copying a large slice.
Production retains one-shot helper calls. The additive plugin inherits
`dashboard_network_plugin.py`, whose pytest-only `NetworkSession` carries each
emitted request through the persistent `network-stream` helper.

## Explicit compatibility

Custom containers, string/comparison behavior, replaced selector providers,
unusual terminal vocabularies and oversized metadata retain reference behavior
through explicit compatibility paths. The shared reference entry helper allows
per-row compatibility without replaying already-yielded history. Original public
parser/history bodies are fatal in the additive Go proof adapter. Reconciliation
itself remains Python orchestration and is not claimed as native.

Whole-poll compatibility uses a task-local reference flag and the original live
module globals. Replaced callbacks are honored before and after awaits; native
selector wrappers use reference clones within that scope. The flag resets in
`finally`, including on cancellation, without changing shared module bindings.

## Oracle and supplementary evidence

The focused target chains prior dashboard ownership adapters and records native
successes, errors, explicit compatibility reasons and unexpected reference calls.
Existing tests and fixtures remain unchanged. New comparisons, runtime cases,
mutation controls and selector sentinels supplement the original oracle.

The focused target passes 91 tests: 44 unchanged originals and 47 additions.
Those same 44 originals pass under the current Python reference and frozen
starting checkout, `a73ffced33800de9435779a9cabef53864455acb`.
The native run records 250 requests, zero native errors and zero unexpected
reference calls. Fourteen intentional compatibility uses are counted separately:
current payload shape, status comparison, status size and terminal vocabulary;
entry provider, entry shape and status comparison; history limit and payload
shape; and custom worker-results iteration, once each. Selector-provider
compatibility is exercised four times, including replacement during an await,
cancellation cleanup and sibling-task isolation.

New cases force mutations at revision-drift and database awaits, change vocabulary
and entry providers between history yields, preserve opaque reasons and duplicate
rows, and reset the scope on cancellation. A 600-shape fleet needs three native
batches; a mixed-fleet case checks that history traffic retains current plans.
Malformed/empty-history lookahead and replaced slice limits have separate guards.
Native failure and malformed/inconsistent replies remain fatal. Null and other
non-string native vocabulary entries are rejected explicitly. A source mutation
that rejects terminal results fails an unchanged parser oracle. Native-only normal
oracles, xdist counters and unset/Bash/Python selector sentinels also pass.

## Commands and results

```bash
make test-go-dashboard-control-outcomes-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All-package Go race tests, vet and module verification pass. Both commands
cross-build for Linux amd64 and arm64 with CGO disabled. The focused target is
included in the bounded Go CI workflow.

Four existing additive startup checks pass: existing and legacy databases,
corrupt-database recovery and rejection when native storage is unavailable.
Independent correctness and security reviews pass after fixing lookahead bounds
and history-limit handling, then preserving live selector replacement across awaits.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 74.32%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 4025 passed | 78.17%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.02%; supplementary combined coverage |

The starting snapshot contains 3716 original tests; the current suite includes
three earlier additions. The full Go matrix adds 306 boundary cases, including
the new adapter's pure native/runtime and explicit compatibility cases. Paired
reference comparisons and source-mutation subprocess controls run separately.
The full native counters record 311 requests, zero errors and zero unexpected
reference calls, with the same fourteen intentional compatibility uses as the
focused run.

The new adapter covers 243 of 288 executable statements, or 84.38%, in the Go
dataset. Forty-five statements remain uncovered, including refusal, compatibility
and reply-validation branches. Combined coverage does not pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 397 missing of 3507 changed lines; fails | 93%; 227 missing of 3507; passes |
| Frozen starting comparison | 90%; 291 missing of 3166 changed lines; passes | 92%; 223 missing of 3166; passes |

The unchanged gate excludes untracked files before the operator commits them.
A supplementary root-level `diff-cover --include-untracked` run includes the new
adapter: native default/frozen coverage is 88%/90%, with 442/336 missing of
3795/3454 changed statements. Combined default/frozen coverage is 92%/92%, with
272/268 missing of those same totals. Bases and thresholds remain unchanged.

GNU-first topology checks, including new files without exemptions, pass. Python/
YAML lint, scoped Markdown, documentation voice and path checks, operator strings,
file budgets and generated CLI checks pass. File budgets use the frozen starting
comparison; default-base differences remain documented in [PARITY](PARITY.md).

Both reference and Go `make test` attempts stop at the unchanged Markdown gate on
third-party files in ignored dependency caches: 1155 reported errors. Later targets
do not run in those attempts; the dashboard matrices run separately. The full
required gate remains red. No test, check or threshold was weakened.

The dashboard image copies the application package directory, so the new module
needs no explicit file-list change. No image, appliance, fleet or performance
proof is claimed for this working tree; the separate benchmark files remain
untouched.
