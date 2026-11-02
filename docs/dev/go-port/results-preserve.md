# Worker report preservation parity

Go selects which newer targeted-refresh reports survive the main poll. Python
keeps network requests, refresh scheduling, audit storage and control-history
reconciliation. The original Python implementation remains the reference.

## Native boundary

`go_preserve.py` projects only worker name, address, report type and producer
timestamp into `poll_preserve_reports`. Report bodies, editable config and opaque
Python values do not cross the helper channel. Go matches the name/address pair,
uses the last current duplicate, validates feed ages and applies the reference's
raw lexical timestamp comparison. Equal timestamps retain the current report.
The supported service keys are strings or null; supplementary comparisons also
cover Boolean/numeric equality and unhashable JSON keys. Python-only custom keys
and NaN key identity are outside this service boundary.

The normal path captures one clock for the complete decision envelope and uses
one helper process for the fleet. The shared native freshness implementation
retains the future tolerance and accepted timestamp formats. A 1000-worker test
checks one call, one clock and the identity of every retained report. A Go unit
case exercises 20,000 rows with map-based matching.

The helper returns ordered index pairs and an optional semantic error. Python
validates every pair, its worker match, ordering and error shape before applying
the plan to the original dictionaries. It copies report references rather than
decoded replicas. The captured report reference is the same object used for the
selection projection, even if the live current report changes during the helper
call; a forced-interleaving regression proves that boundary. Malformed helper
replies and transport failures fail closed;
they never call the original implementation. For a later malformed report or
unhashable key, preceding valid replacements happen before the corresponding
Python exception, retaining the reference's partial-update behavior.

An explicitly replaced `worker_refresh.feed_age` callback uses a separate Python
compatibility path, preserving callback order and decisions. This is an
intentional interposition boundary, counted separately from native completion;
native failures cannot select it. Unset, Bash and Python selection retain the
original implementation and never invoke the native executable.

Terminal control parsing, bounded control-history iteration, audit caps and
revision reconciliation remain Python. The audit loop reads between awaited
storage calls; this slice does not change that ordering or claim those policies
as native. Other remaining provider/settings and poll orchestration work stays
listed in [PARITY](PARITY.md).

## Oracle and supplementary evidence

The additive plugin makes the original preservation body fatal under Go
selection. Its reference clone is available only in explicit paired contexts.
Counters distinguish completed native plans, semantic errors inside those
plans, transport errors, intentional callback compatibility and unexpected
reference calls.

The focused target passes 78 tests: 26 unchanged originals from the worker
refresh and DataService aggregation/synchronization files, plus 52 additive
cases. The same 26 originals pass on the frozen starting checkout and the
current reference. Existing tests, fixtures and thresholds are unchanged.

The additions cover matching, duplicate precedence, nullable/falsy/malformed
reports, accepted timestamp spelling and lexical order, report identity,
partial updates, callback interposition and native failure boundaries. One
source-overlay control disables replacement selection; the unchanged original
main-poll preservation test fails. Three sentinel cases prove that unset, Bash
and Python selection do not call a fake native executable.

Focused counters record 44 completed native plans, including five expected
`AttributeError` and two expected `TypeError` outcomes inside the plans. There
are zero transport errors, two deliberate callback-compatibility calls and zero
unexpected reference calls. Injected replies and mutation subprocesses are
separate controls. The frozen oracle remains
`a73ffced33800de9435779a9cabef53864455acb`.

## Commands and results

```bash
make test-go-dashboard-preserve-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both commands cross-build for Linux amd64 and arm64
with CGO disabled. The focused target is included in the bounded Go CI workflow.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 80.85%; total gate passes |
| Go selection with storage/native-body adapters | 3846 passed | 78.46%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.56%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three additions from earlier
rounds. The Go matrix adds 127 native boundary cases without paired reference
comparisons. Its preservation counters record 134 completed plans, including one
expected inner `AttributeError`, one explicit callback-compatibility call and zero
unexpected reference calls. All 42 executable statements in the new adapter are
covered by the Go dataset. Combined coverage includes retained reference paths;
it does not pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 89%; 282 missing of 2614 changed lines; fails | 93%; 165 missing of 2614; passes |
| Frozen starting comparison | 92%; 176 missing of 2273 changed lines; passes | 92%; 161 missing of 2273; passes |

The patch gates include the committed RigForge adapter. They omit the new
untracked preservation adapter until the operator commits it; both XML datasets
measure that module. Run the patch gates again after that commit. Bases and
thresholds are unchanged.

Python/YAML lint, documentation voice and path checks, operator strings,
GNU-first topology checks, file budgets and generated CLI checks pass. Scoped
Markdown checks pass with the repository's pinned tool version. The topology scan
includes new files without exemptions. File budgets use the documented
frozen-start override; default-base differences remain in [PARITY](PARITY.md).
Independent correctness and security reviews pass on the supported boundary.

Both reference and Go `make test` attempts stop at the unchanged Markdown gate on
third-party files in local dependency caches. Later targets do not run in those
attempts; the dashboard matrices above run separately. The full required gate
remains red. No existing test, check or threshold was weakened.

The dashboard image copies the complete backend package. Image, appliance and
fleet proof for this working-tree slice remain pending. Checks use locked Python
3.11, Go 1.27.1, UTC and worktree-local offline caches. Benchmark files and live
stacks are unchanged.
