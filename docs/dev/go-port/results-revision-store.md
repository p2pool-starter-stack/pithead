# Dashboard worker revision storage parity

This round moves worker revision SQL, drift persistence and current-revision
visibility policy into Go. Python retains the database lock, clocks, pruning
sample, live connection selection, commit, error handling, post-commit detection
and awaited audit callbacks. No host or network probe is added.

## Native boundary

Four fixed storage operations reuse the existing connection and transaction:
`worker-revision-prepare`, `worker-revision-write`, `worker-revision-prune` and
`worker-revision-drift`. Every query binds its parameters. The prepare operation
reads the prior row and selects which stored field carries drift forward; the
reply contains the captured row once and an immutable field selection. No pending
operation or transaction token is retained across helper calls.

The original orchestration still reads under its lock, resolves drift policy,
calls the clock, writes, calls the pruning sampler, optionally deletes expired
rows and commits in that order. Its detection result is emitted only after a
successful commit. Each write, prune and commit uses the live connection at its
original point, including a connection changed by an earlier callback.

The current-revision read returns its captured row and native visibility flag.
Python consumes the flag after releasing the lock, preserving the reference's
read and return boundaries. Accepted worker and reported-revision objects stay
with the Python caller. SQLite scalar wire tags preserve BLOB and nonfinite
values already present in a database.

## Explicit compatibility

Custom connections, noncanonical values and inputs outside native text bounds
use the corresponding reference helper at its original phase. Replaced drift
providers see the captured row once after the read; no SELECT is replayed. Clock
and random providers remain Python calls. Reference extraction retains cursor
lifetime and the same transaction, error and callback sequence.

## Oracle and supplementary evidence

The 139 original revision, worker-audit, surrogate, schema, Inspect drift and
mixin-atomicity tests pass under the current Python reference and frozen starting
checkout, `a73ffced33800de9435779a9cabef53864455acb`. Existing tests and fixtures
remain unchanged. The unselected reference arm also passes all 139 tests after
reference-helper extraction.

The focused target passes 160 tests: those 139 originals and 21 additions. It
records 173 prepare calls, 173 writes, 21 currency reads and one prune. Native
errors and unexpected reference calls are zero. Two intentional compatibility
selections cover one replaced drift provider and one custom cursor.

The additive plugin chains all prior dashboard ownership guards and makes the
reference SQL/policy helper bodies fatal. Separate clones serve explicit
compatibility and paired reference comparisons. Two Go source mutations break
unchanged Inspect drift tests: one makes the native write fail, and the other
makes the native currency read fail. A fresh xdist process proves prepare, write
and currency operations with zero errors, compatibility or fallback. Another
control deliberately calls a fatal reference helper and verifies its failure
counter. Unset, Bash and Python selectors never invoke the native helper.

Added cases cover a real revision round trip, captured-row reconstruction,
provider replacement without query replay, BLOB and oversized legacy fields,
malformed native results, strict mutation acknowledgments, absent-row native
visibility and reference truthiness/inequality behavior. The native absent-row
case makes reference compatibility fatal. Go unit tests additionally cover
classification, transaction commit/rollback, pruning, scalar truthiness and
argument boundaries.

## Commands and results

```bash
make test-go-dashboard-revision-store-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All-package Go race tests, vet and module verification pass. Both commands
cross-build for Linux amd64 and arm64 with CGO disabled. The focused target is
included in the bounded Go CI workflow. Four existing additive startup cases
pass: existing and legacy databases, corrupt-database recovery and missing-native
storage refusal. Independent correctness and security reviews pass.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 72.84%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 4085 passed | 78.48%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.04%; supplementary combined coverage |

The starting snapshot contains 3716 original tests; the current suite includes
three earlier additions. The full Go matrix adds 366 boundary cases; source
mutations and paired comparison controls run separately. Full counters record
171 prepare calls, 171 writes, 42 currency reads and one prune, with no native
errors or unexpected reference calls. The same two intentional compatibility
cases are recorded.

The new adapter covers 97 of 108 executable statements in the native dataset
(89.81%). Its extracted reference helpers cover 8 of 14 statements in that dataset;
the separate reference arm exercises the SQL helpers. The final proof-only
changes strengthen canonical no-compatibility and fatal-counter guards; they do
not change application source or the full matrix's coverage. Combined coverage
does not pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 441 missing of 3969 changed lines; fails | 93%; 270 missing of 3969; passes |
| Frozen starting comparison | 90%; 335 missing of 3628 changed lines; passes | 92%; 266 missing of 3628; passes |

The unchanged gate excludes untracked files before the operator commits them.
A supplementary root-level `diff-cover --include-untracked` run includes both new
application modules: native default/frozen coverage is 88%/90%, with 458/352 missing
of 4091/3750 changed statements. Combined default/frozen coverage is 93%/92%, with
281/277 missing of those same totals. Bases and thresholds remain unchanged.

GNU-first topology checks include new files without exemptions and pass. Python/
YAML lint, scoped Markdown, documentation voice and path checks, operator strings,
file budgets and generated CLI checks pass. File budgets use the frozen starting
comparison; default-base differences remain
documented in [PARITY](PARITY.md). The original worker store remains below its
448-line ceiling; no budget was raised.

Both reference and Go `make test` attempts pass Python lint and stop at the
unchanged Markdown gate on third-party files in ignored dependency caches:
1155 reported errors. Later targets do not run in those attempts; the full
dashboard matrices run separately. The full required gate remains red. No test,
check or threshold was weakened.

No image, appliance, fleet or performance proof is claimed for this working tree;
the separate benchmark files remain untouched.
