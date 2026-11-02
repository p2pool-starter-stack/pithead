# Dashboard worker audit cap parity

Go compiles the name-admission and per-worker audit-count comparisons into bounded
policy tables. Python retains membership checks, expiry arithmetic, ordered
deletions, window reservations and writes, saturation episodes, revision storage,
audit writes and all awaited callbacks. This slice adds no host or network probes.

## Native boundary

`audit-cap-policy` accepts one exact integer limit from zero through 4096. It
returns two tables of length `limit + 2`: whether each name count fills the limit,
and the allowed/first-over pair for each audit count. The last entry represents
all larger nonnegative counts. Python clamps the current exact integer count to
that entry and consumes the native comparison result.

Only the limit crosses the helper boundary. Worker names, timestamps, counts,
window maps, episode markers, reasons and service objects stay in Python.
Malformed requests and invalid replies fail explicitly. Native errors do not
select reference comparison policy.

The adapter retains at most sixteen immutable tables, keyed only by limit. Cache
hits reuse pure policy, with the current state read at every comparison. Changes
to either live limit select its corresponding plan independently. A flood of
events under one limit therefore reuses one compiled policy. Actual native plan
requests and per-helper selections are recorded separately in the proof adapter.

The existing-name admission return remains Python. For a new name, expiry
deletions happen before the native name-count decision. The episode field is read
only on saturation. The per-worker counter write remains unconditional and
precedes the native spend decision, including on refused attempts.

## Explicit compatibility

Custom or negative counts and noncanonical limits use the extracted reference
comparison helper at its original point. Earlier expiry deletions and counter
writes are retained when a later comparison raises. The reference count helper
reads the live cap separately for its less-than and equality comparisons, so a
custom comparison can change the second lookup. Python continues to resolve
providers and module globals in the original orchestration order.

## Oracle and supplementary evidence

The additive adapter chains the prior dashboard ownership guards and makes the
original public admission/cap bodies and comparison helpers fatal. Preserved
Python orchestration calls native comparison helpers; explicit compatibility
uses reference clones without replaying earlier mutations.

The same 47 focused original reconciliation, rig-edit, drift and name-cap tests pass under
the current Python reference and frozen starting checkout,
`a73ffced33800de9435779a9cabef53864455acb`. Existing tests and fixtures remain
unchanged. New comparison, runtime and mutation cases supplement that oracle.

The focused target passes 96 tests: those 47 originals and 49 additions. It records
30 native plan requests and 349 helper selections: 136 admission comparisons and
213 spend comparisons. These selection counts include thirteen intentional
compatibility uses: five name-value cases, seven count-value cases and one
missing-count-limit case. Native errors and unexpected reference calls are zero.

Added cases cover shared/independent limit plans, overflow counts, immutability,
sixteen-entry eviction, malformed replies, custom/negative counts and unsupported
limits. They preserve existing-name early returns, expiry deletion prefixes,
count writes before errors, live cap mutation between comparisons and a replaced
admission callback. Fresh source mutations break unchanged name-cap and rig-edit
flood oracles. Separate controls prove both native policy helpers with no
compatibility, xdist counter aggregation and unset/Bash/Python selector isolation.

The plugin declaratively inherits the control-outcome, egress and network
ownership guards. Its pytest-only persistent network session executes every
emitted plan request. Production uses the existing one-shot helper transport.

## Commands and results

```bash
make test-go-dashboard-audit-cap-parity
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
| Current reference | 3719 passed | 73.94%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 4053 passed | 78.29%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.04%; supplementary combined coverage |

The starting snapshot contains 3716 original tests; the current suite includes
three earlier additions. The full Go matrix adds 334 boundary cases. Paired
reference comparisons and source-mutation subprocess controls run separately.
Full counters record 28 native plan requests and 300 helper selections: 112
admission and 188 spend. The same thirteen intentional compatibility uses are
included; native errors and unexpected reference calls remain zero.

The new adapter covers all 66 executable statements in the native dataset.
The plugin defers application imports into its hooks so startup lines are traced;
coverage flags, thresholds and original suites remain unchanged. Combined coverage
does not pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 442 missing of 3804 changed lines; fails | 92%; 272 missing of 3804; passes |
| Frozen starting comparison | 90%; 336 missing of 3463 changed lines; passes | 92%; 268 missing of 3463; passes |

The unchanged gate excludes untracked files before the operator commits them.
A supplementary root-level `diff-cover --include-untracked` run includes the new
adapter: native default/frozen coverage is 88%/90%, with 442/336 missing of
3870/3529 changed statements. Combined default/frozen coverage is 92%/92%, with
272/268 missing of those same totals. Bases and thresholds remain unchanged.

GNU-first topology checks include new files without exemptions and pass. Python/
YAML lint, scoped Markdown, documentation voice and path checks, operator strings,
file budgets and generated CLI checks pass. File budgets use the frozen starting
comparison; default-base differences remain documented in [PARITY](PARITY.md).

Both reference and Go `make test` attempts stop at the unchanged Markdown gate on
third-party files in ignored dependency caches: 1155 reported errors. Later targets
do not run in those attempts; the dashboard matrices run separately. The full
required gate remains red. No test, check or threshold was weakened.

No image, appliance, fleet or performance proof is claimed for this working tree;
the separate benchmark files remain untouched.
