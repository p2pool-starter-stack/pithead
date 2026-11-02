# Audit query parity

Go selects and orders the security panel's audit feed, filters both security-log
surfaces and normalizes their navigation bounds. Python retains database and
bounded log reads, timestamp parsing, string conversion, Unicode lowercasing,
query stripping, HTTP orchestration and JSON responses. Access-log normalization
and failure aggregation remain Python; this is another hybrid backend slice.

## Native boundary

The typed configuration protocol carries three policies. `audit-merge` receives
only row identifiers, timestamps, source flags and synthetic identity tokens. Go
deduplicates database and live-log entries, keeps the database copy on collisions
and sorts timestamps in stable descending lexical order. Duplicate database IDs
retain their first insertion position and last value. Empty-ID live entries use
the same object-identity key, including collisions with real IDs. Python resolves
the selected indices to original database rows or shallow control-log copies.

Database rows and their IDs are captured before the live reader runs. Timestamps
are captured afterward, preserving a reader that updates existing database rows.
Each provider is called once. Database rows retain their original object identity;
the selection uses captured metadata rather than rereading mutable rows in Go.

`audit-filter` receives one captured envelope containing epochs, lowercased field
strings, bounds and query. One native call makes both time and text decisions,
so there is no provider read between native filtering phases. Go returns ascending
indices into the original rows. The window includes its lower bound and excludes
its upper bound. Direct-helper NaN and infinity behavior follows the original
comparison branches; integer bounds are compared without float rounding.
Python retains its date parser and representation/Unicode rules, including lone
surrogates. Opaque row contents do not enter the bridge when no text search needs
them. A 20,000-row Go case verifies the batch decision.

`audit-query` receives stripped query text and Python-parsed numeric bounds. Go
discards non-finite bounds, caps the query at 200 Python code points and converts
an empty query to None. Python preserves query-read order and float syntax.

Malformed native replies and transport errors raise; they do not select a
reference implementation. The adapter checks index type, range, uniqueness and
filter order, plus normalized query result types and limits.

## Explicit compatibility

Filtering retains the lazy Python policy for custom iterables/dictionaries,
nonstandard bounds or query objects, replaced epoch providers and nonscalar
search values. Search integers above 1000 bits and integer timestamps above
1023 bits also retain that path, preserving conversion failures and short-circuit
order. Arbitrarily wide numeric bounds remain native.

Merging retains Python hash, equality, sorting and iteration behavior when a
provider returns noncanonical containers or nonstring IDs/timestamps. A live
reader that changes database ID types keeps the previously captured database
keys. These paths are counted separately; normal scalar rows use native policy.

## Oracle and supplementary evidence

The additive plugin makes the three public reference bodies fatal under Go
selection. Its parent retains the earlier storage and policy guards. Paired
contexts restore reference clones; worker reports aggregate native completions,
errors, compatibility uses and unexpected reference calls.

The focused target passes 100 tests: 43 unchanged service/filter/HTTP route tests
and 57 added comparisons and boundary controls. The same 43 originals pass under
the current reference and frozen starting checkout,
`a73ffced33800de9435779a9cabef53864455acb`. Existing tests and fixtures are unchanged.

Added cases cover stable ties, duplicate IDs, database precedence, no-ID rows,
synthetic collisions, row identity, provider ordering and mutation, half-open
windows, numeric boundaries, Unicode, malformed replies and transport failures.
A forced interleaving verifies that timestamp and text selection use the same
captured generation. Reversing Go's lower-bound comparison fails an unchanged half-open
window test. Separate controls prove xdist counter aggregation and that unset,
Bash and Python selection never invoke native helpers.

Focused counters record 32 filter, 14 merge and 30 query completions, eight filter
and seven merge compatibility uses, and zero unexpected reference calls. Mutation,
selector and counter subprocesses are separate controls.

## Commands and results

```bash
make test-go-dashboard-audit-query-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both commands cross-build for Linux amd64 and arm64 with
CGO disabled. The focused target is included in the bounded Go CI workflow.
Four existing additive runtime checks also pass: existing and legacy startup,
corrupt-database recovery and rejection when native storage is unavailable.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 78.93%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 3932 passed | 78.01%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.45%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three earlier additions.
The Go matrix adds 213 native boundary cases without paired reference comparisons.
The new adapter's 95 executable statements are covered in the Go dataset.
Full worker-aggregated query counters record 24 filter, 11 merge and 24 query
completions, two filter and two merge compatibility uses, and zero unexpected
reference calls. Reference coverage falls because that mode does not execute the
new native adapter; combined coverage does not pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 341 missing of 2939 changed lines; fails | 93%; 190 missing of 2939; passes |
| Frozen starting comparison | 90%; 235 missing of 2598 changed lines; passes | 92%; 186 missing of 2598; passes |

The unchanged gate excludes untracked files before the operator commits them.
A supplementary root-level `diff-cover --include-untracked` run includes the new
adapter: native default/frozen coverage is 88%/91%, with 341/235 missing of
3034/2693 changed statements. Combined default/frozen coverage is 93%/93%, with
190/186 missing of those same totals. Bases and thresholds remain unchanged.

Python/YAML lint, scoped Markdown checks, documentation voice and path checks,
operator strings, GNU-first topology checks, file budgets and generated CLI
checks pass. Topology includes new files without exemptions. File budgets use the
documented frozen-start override; default-base differences remain in
[PARITY](PARITY.md). Independent correctness and security reviews pass.

Both reference and Go `make test` attempts stop at the unchanged Markdown gate on
third-party files in ignored dependency caches: 1155 reported Markdown errors.
Later targets do not run in those attempts; the dashboard matrices above run
separately. The full required gate remains red. No existing test, check or
threshold was weakened.

The dashboard image copies the complete backend package. Image, appliance and
fleet proof for this working-tree slice remain pending. Checks use locked Python
3.11, Go 1.27.1, UTC and worktree-local caches. No benchmark file, live stack,
existing check or threshold changed.
