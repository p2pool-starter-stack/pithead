# Control audit log parity

Go normalizes the bounded control-log tail and plans its replay into durable
audit history. Python retains the tail read, JSON decoding, value-to-text
conversion, sequential database writes and explicit replaced-reader behavior.
Access-log normalization, log filtering/grouping and audit route orchestration
remain Python.

## Native boundary

`audit-recent` uses the existing typed configuration protocol. Python reads the
same 256 KiB tail, drops incomplete or invalid JSON lines through the existing
reader, and projects only `ts`, `id`, `actor`, `action`, `status` and `keys`.
Foreign fields never enter the helper. Standard-library string conversion stays
in Python, preserving Boolean, number, nested-container and surrogate behavior
without another implementation of Python representation rules.

Go applies the existing ASCII whitelist and exact field caps, reverses the
complete normalized list and then applies Python slice limits. All input rows
are normalized before slicing. None, Boolean, ordinary and arbitrarily wide
integer limits retain their original results; invalid JSON-domain limit types
raise `TypeError`. An unreadable tail remains an empty I/O result without a native
call. The standalone `_clean` function remains Python for other callers.

`audit-mirror` receives the normalized newest-first list and returns fixed
oldest-first write records. It skips empty IDs, supplies the original defaults,
forces `source=control`, drops extra fields and preserves field order. A normal
mirror reads once, uses one call for each native policy and awaits each write in
sequence. Preview and terminal rows sharing an ID retain their durable outcome.
A write failure stops at the same prefix; writes are neither batched nor retried.

Python validates complete ordered field sets, string values, nonempty mirror IDs,
the fixed source and the input row-count bound. Decode failures, malformed native
rows and transport failures raise without selecting the reference implementation.

The shared Python mirror loop keeps replaced `recent_changes` readers observable
through an explicit compatibility path. That path uses the original lazy row
iterator, so mutations between awaited writes, opaque values and later-entry
errors retain their original timing. Normal native readers do not take this path.
Installing the new reader refreshes the editor's captured default provider only
when it still points to the reference function; a deliberately replaced provider
keeps its identity.

## Oracle and supplementary evidence

The additive plugin makes the public reference reader and extracted row-planner
bodies fatal under Go selection. Paired contexts expose reference clones.
Native completions, structured errors, intentional reader compatibility and
unexpected reference calls are counted across xdist workers.

The focused target passes 71 tests: 34 unchanged originals and 37 additive cases.
The original audit-service module includes regressions for helpers that remain
Python; native ownership is claimed only for the recent control-log result and
mirror planning. The same 34 originals pass against the current reference and
frozen starting checkout, `a73ffced33800de9435779a9cabef53864455acb`. Existing tests,
fixtures and thresholds remain unchanged.

New comparisons cover hostile text, field caps, missing and foreign fields,
Python value conversion, non-finite numbers, lone surrogates, limits and mirror
ordering. Runtime cases cover read-once batching, disabled control, sequential
write failure, lazy replaced-reader interleaving, malformed replies and captured
editor-provider installation. A source mutation disables newest-first ordering
and fails an unchanged reader test. Separate controls prove worker counter
aggregation and that unset, Bash and Python selection never invoke native helpers.

Focused counters record 24 recent and nine mirror completions. Deliberately bad
inputs produce one recent `TypeError` and one mirror `AttributeError`. One
replaced-reader interposition is recorded separately, with zero unexpected
reference calls. Mutation and selector subprocesses are separate controls. Go
units include a 1800-row input exceeding the production tail bound and verify
input immutability.

## Commands and results

```bash
make test-go-dashboard-audit-log-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both commands cross-build for Linux amd64 and arm64 with
CGO disabled. The focused target is included in the bounded Go CI workflow.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 79.57%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 3907 passed | 78.11%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.42%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three earlier additions.
The Go matrix adds 188 native boundary cases without paired reference comparisons.
Worker-aggregated audit-log counters record 27 recent and seven mirror completions,
one intentional replaced-reader interposition and zero unexpected reference calls.
Reference coverage declines from 79.82% to 79.57% because that run does not execute
the new native adapter. The union retains both modes; it does not pass the Go-only
total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 342 missing of 2910 changed lines; fails | 93%; 191 missing of 2910; passes |
| Frozen starting comparison | 90%; 236 missing of 2569 changed lines; passes | 92%; 187 missing of 2569; passes |

These patch gates include this round's tracked production Python changes. Bases
and thresholds remain unchanged.

Python/YAML lint, scoped Markdown checks, documentation voice and path checks,
operator strings, GNU-first topology checks, file budgets and generated CLI
checks pass. Topology includes new files without exemptions. File budgets use the
documented frozen-start override; default-base differences remain in
[PARITY](PARITY.md). Independent correctness and security reviews pass.

Both reference and Go `make test` attempts stop at the unchanged Markdown gate on
third-party files in local dependency caches. Later targets do not run in those
attempts; the dashboard matrices above run separately. The full required gate
remains red. No existing test, check or threshold was weakened.

The dashboard image copies the complete backend package. Image, appliance and
fleet proof for this working-tree slice remain pending. Checks use locked Python
3.11, Go 1.27.1, UTC and worktree-local offline caches. No benchmark file, live
stack, existing check or threshold changed.
