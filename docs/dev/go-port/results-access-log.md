# Access log summary parity

Go normalizes and summarizes the security panel's retained access records in one
batch. Python retains the bounded filesystem/gzip reader, JSON decoding, numeric
and text conversion providers, HTTP orchestration and explicit compatibility.
The earlier native audit filter still narrows visible entries after aggregation;
failure counters continue to describe all retained records.

## Native boundary

`audit-access` uses the typed configuration protocol. An unavailable active log
returns the original five-field unavailable response without reading the clock
or evaluating unused limit/provider values. An available log is read once and
uses one clock value before the immutable native batch is built.

Python applies the existing float/int coercion and value-to-text conversion.
Go replaces non-finite timestamps with zero, clamps statuses to the HTTP range,
selects known methods, and applies the existing ASCII sanitizer and URI/user
caps. It counts ordinary 401s with ages from zero through 86400 seconds,
excluding only the exact `boot-health-v1` marker. The latest failure timestamp
uses all retained records, independent of display limits and later filters.

Go sorts finite timestamps in stable descending order before applying the limit.
None, Boolean, negative and ordinary integer limits retain Python slice behavior.
Integer clocks round to float before timestamp subtraction; signed-zero ties keep
their first value. Rotation compares the full failure count to the supplied
threshold, preserving numeric and NaN behavior. No records are written or retried.

The adapter validates ordered field sets, availability, counts, timestamp/status
types, known methods and sanitized text limits. Invalid native replies and
transport failures raise without invoking reference policy. No per-row native
process is created; Go unit coverage includes a 20,000-row batch.

The reference loop is extracted into `_access_summary_rows` and shared by public
reference selection and explicit compatibility. The public reference reader,
clock order and output behavior remain unchanged. The sole production consumer
looks up `audit_service.access_summary` dynamically, so no captured alias needs
refreshing.

## Explicit compatibility and read bounds

The unchanged Python reader accepts the active file plus at most two allowlisted
backup generations. Each contributes at most 4 MiB of decoded JSON; gzip input
is also bounded. Plain files are preferred while compression is in progress.
Incomplete, malformed, symlink and special-file handling stays in that reader.

Native batches are limited to 100,000 rows before projection. A 12 MiB retained
input can contain more than four million minimal JSON records, whose typed
projection would exceed the native protocol's 64 MiB input limit. Larger exact
lists/tuples use the shared Python loop with reason `retained-row-count`.
A 100,001-row regression verifies complete failure counting with zero visible
entries and no native call.

Other explicit reasons cover custom row/iterator shapes, replaced sanitizer,
numeric, text, finite-check and method providers, unusual slice/clock/threshold
values and oversized integer conversion. Raw numeric/text integers above 1000
bits, clock integers above 1023 bits and parsed status integers above 1000 bits
retain reference conversion and error order. Replaced readers returning ordinary
bounded rows can still use native policy. Compatibility reasons are counted;
native errors never trigger compatibility.

## Oracle and supplementary evidence

The additive plugin makes the original public summary body fatal under Go
selection and chains the earlier storage and policy guards. Comparison contexts
restore a reference clone. Counters aggregate native calls, errors, explicit
compatibility reasons and unexpected reference calls across xdist workers.

The focused target passes 115 tests: 59 unchanged audit/access/HTTP route tests
and 56 added comparisons and boundary controls. The same 59 originals pass under
the current reference and frozen starting checkout,
`a73ffced33800de9435779a9cabef53864455acb`. Existing tests and fixtures are unchanged.

Added cases cover hostile text, numeric coercion, probe markers, stable ties,
clock/window/limit boundaries, provider interposition, lazy failures and malformed
native replies. A forced interleaving mutates nested URI/user inputs after their
text projection and verifies that the native result uses the captured generation.
A source mutation changes the rotation threshold comparison and fails an
unchanged rotation-hint test. Separate controls prove xdist aggregation, unset/
Bash/Python selection isolation and native-only execution of unchanged normal
oracles.
JSON-input preservation is checked separately from result equality; an injected
row mutation proves that guard fails. Opaque-object comparisons retain their
reference side effects.

Focused counters record 72 native completions, zero native errors and zero
unexpected reference calls. Explicit compatibility reasons are reported
separately. Mutation, counter and selector subprocesses are separate controls.

## Commands and results

```bash
make test-go-dashboard-access-log-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both commands cross-build for Linux amd64 and arm64 with
CGO disabled. The focused target is included in the bounded Go CI workflow.
Four existing additive startup checks also pass: existing and legacy databases,
corrupt-database recovery and rejection when native storage is unavailable.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 78.11%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 3955 passed | 78.13%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.43%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three earlier additions.
The Go matrix adds 236 native boundary cases without paired reference comparisons.
The new adapter covers 118 of 126 executable statements, or 93.65%, in that Go
dataset. Shape and invalid-limit compatibility also have supplementary paired
cases; eight executable compatibility statements remain uncovered in these full
matrices. Full worker counters record 54 native completions, 13 explicit
compatibility uses across ten reasons, zero native errors and zero unexpected
reference calls. The separate union does not pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 343 missing of 3037 changed lines; fails | 93%; 190 missing of 3037; passes |
| Frozen starting comparison | 91%; 237 missing of 2696 changed lines; passes | 93%; 186 missing of 2696; passes |

The unchanged gate excludes untracked files before the operator commits them.
A supplementary root-level `diff-cover --include-untracked` run includes the new
adapter: native default/frozen coverage is 88%/91%, with 351/245 missing of
3163/2822 changed statements. Combined default/frozen coverage is 93%/93%, with
198/194 missing of those same totals. Bases and thresholds remain unchanged.

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
