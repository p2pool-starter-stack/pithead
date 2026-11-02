# Dashboard revision metadata parity

This round moves standalone revision metadata normalization into Go. Python
retains worker admission, window reservation, revision storage, cap consumption,
audit writes and all awaited callbacks. It adds no host or network probes.

## Native boundary

`config_meta_policy` accepts exactly four typed field descriptors and returns
Boolean acceptance flags. Python projects only `source`, `revision`, `changed_at`
and `last_change_id`. Exact strings up to 64 code points travel with their length;
longer strings become a capped length-only descriptor, and ordinary non-string
values become kind-only descriptors. Individual text values are bounded to 256
UTF-8 bytes. Whole reports, workers, unknown fields and opaque rejected objects
stay off the wire.

Go applies the shared token, timestamp and source rules. Tokens retain the 64
character bound, ASCII vocabulary and permitted final newline. Timestamps retain
Python regex behavior, including Unicode decimal digits and a permitted final
newline. This round fixes a category-version mismatch: Go 1.27 recognizes 110
newer decimal digits outside locked Python 3.11's Unicode 14 table. The shared Go
timestamp validator rejects those digits, retaining the reference's 660 digits.
This correction also applies to native enriched-report parsing.

The adapter binds the standalone parser and the captured aliases in
`xmrig_client` and `worker_change_audit`. Validation remains before worker
admission, revision storage and event identifier construction. The existing
asynchronous revision/audit orchestration is unchanged. Native enriched-report
parsing remains documented in [RigForge results](results-rigforge.md).

A thread-safe LRU cache retains at most 256 immutable acceptance tuples, keyed by
bounded descriptors. Equal metadata reuses native policy while each result keeps
its own original accepted objects. Concurrent misses may perform duplicate
bounded calls. Native errors and malformed replies fail explicitly.

## Explicit compatibility

Custom dictionaries, keys, values, string subclasses and surrogate-containing
short strings use the original parser. Replaced or missing token/regex providers,
source vocabulary, token limit and module-level builtins also use the reference
path. Provider guards use identity checks, avoiding extra custom comparisons.
Compatibility executes once at the parser boundary, preserving source-first
access, live lookups, exception order and accepted-object identity. These paths
are recorded separately from native calls.

## Oracle and supplementary evidence

The 99 original tests in `test_rig_config_meta.py`, `test_worker_change_audit.py`,
`test_worker_config_surrogates.py` and `test_worker_revision.py` pass under the
current Python reference and the frozen starting checkout,
`a73ffced33800de9435779a9cabef53864455acb`. Existing tests and fixtures remain
unchanged. The focused target passes 137 tests: those 99 originals and 38
additions. It records 51 native policy calls, zero native errors and zero
unexpected reference calls. Its 24 intentional compatibility selections include
fourteen container cases, two value cases, one key case, two token-provider cases,
one regex-provider case, one source-provider case, two token-limit cases and one
builtin-provider case.

The additive plugin chains all earlier dashboard ownership guards and makes the
original parser body fatal. Reference clones are available only through explicit
compatibility or paired reference comparisons. A source mutation reverses native
revision acceptance and fails an unchanged parser oracle. A separate fresh
process runs unchanged parser/pass-through tests under xdist with native calls,
no compatibility and no fallback. Unset, Bash and Python sentinels never invoke
the native helper.

Added cases cover accepted-object identity through cache hits, 256-entry eviction,
short/oversized surrogates, opaque rejected values, Unicode-version differences,
trailing newlines, custom dictionary access order, custom keys and live/missing
providers. Invalid reply shapes and transport errors fail without reference
fallback. Existing worker drift and surrogate oracles retain validation before
storage and the original callback sequence.

## Commands and results

```bash
make test-go-dashboard-config-meta-parity
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
| Current reference | 3719 passed | 73.43%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 4072 passed | 78.44%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.07%; supplementary combined coverage |

The starting snapshot contains 3716 original tests; the current suite includes
three earlier additions. The full Go matrix adds 353 boundary cases. Paired
comparisons and source-mutation subprocess controls run separately. Full counters
record 49 native metadata policy calls, zero native errors and zero unexpected
reference calls. Its 171 intentional compatibility selections include 161
container cases and the same other ten cases as the focused run. All 89 executable
statements in the new adapter are covered in the native dataset. Application
imports remain deferred inside proof-plugin hooks so startup is traced.

The final matrices were rerun after formatting the new adapter and proof plugin;
assertion results and coverage match the earlier run. Combined coverage does not
pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 442 missing of 3871 changed lines; fails | 92%; 272 missing of 3871; passes |
| Frozen starting comparison | 90%; 336 missing of 3530 changed lines; passes | 92%; 268 missing of 3530; passes |

The unchanged gate excludes untracked files before the operator commits them.
A supplementary root-level `diff-cover --include-untracked` run includes the new
adapter: native default/frozen coverage is 88%/90%, with 442/336 missing of
3960/3619 changed statements. Combined default/frozen coverage is 93%/92%, with
272/268 missing of those same totals. Bases and thresholds remain unchanged.

GNU-first topology checks include new files without exemptions and pass. Python/
YAML lint, scoped Markdown, documentation voice and path checks, operator strings,
file budgets and generated CLI checks pass. File budgets use the frozen starting
comparison; default-base differences remain
documented in [PARITY](PARITY.md).

Both reference and Go `make test` attempts pass Python lint after formatting and
stop at the unchanged Markdown gate on third-party files in ignored dependency
caches: 1155 reported errors. Later targets do not run in those attempts; the
full dashboard matrices run separately. The full required gate remains red.
No test, check or threshold was weakened.

No image, appliance, fleet or performance proof is claimed for this working tree;
the separate benchmark files remain untouched.
