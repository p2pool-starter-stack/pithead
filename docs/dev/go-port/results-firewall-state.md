# Dashboard firewall-state parity

Go classifies the dashboard's already-read host firewall status and plans its
posture/topology warning overlay. Python retains the status file, JSON reader,
clock, arithmetic providers, builder calls and in-place summary updates. This
slice adds no host or network probes.

## Native boundary

`firewall-status-valid` checks exact numeric types before the clock is read.
Boolean return codes and Boolean/string timestamps remain invalid. Timestamps
must be finite and within the inclusive range `[-2**53, 2**53]`. Invalid fields
return unverified without sampling the clock.

Python captures the clock and evaluates the original subtraction and absolute
value. `firewall-status-result` applies the inclusive 360-second freshness bound
and maps return codes: zero is enforced, 1/2/4/5 are missing and other codes are
unverified. NaN ages retain Python's comparison behavior; infinite ages are stale.
Arithmetic exceptions, large-integer precision and provider side effects remain
Python-owned.

Only numeric kind/value metadata crosses the helper boundary. Paths, unrelated
JSON fields and opaque objects remain in Python. Native integer metadata is
limited to 1000 bits under the existing 2 MiB network request limit.

`firewall-plan` determines the enabled builder's firewall flag, warning flag and
prefix. Python calls the builder once and keeps the exact result and summary
objects. It appends `firewall_state`, then sets `level`, then formats the label;
missing labels and callback exceptions preserve the original mutation prefix.
Firewall opt-out retains the direct Python builder call without reading status.

Reader errors and malformed/deep JSON remain at the original Python boundary.
The public reference functions share extracted loaded-status, age-result and
resolved-overlay helpers with explicit compatibility paths. No file read, clock,
arithmetic step or state provider is repeated to enter compatibility.

## Explicit compatibility

Replaced open/JSON/clock/absolute-value and shared-policy providers, changed
status constants or labels, oversized integers, custom age values and unusual
firewall/state inputs retain reference behavior. Eligibility checks precede
operations that would otherwise change provider side effects. State truthiness
is evaluated once, including when a status provider returns a false value. A
replaced status callback returning a canonical state still uses the native plan.

Exercised reasons are `abs-provider`, `clock-provider`, `wide-integer`,
`age-shape`, `firewall-shape`, `plan-label` and `state-value`.
Other provider/constant refusal branches exist but are not all independently
proved by the focused matrix. Native errors and invalid replies raise without
selecting reference policy.

## Oracle and supplementary evidence

The additive plugin chains the previous dashboard ownership guards and makes
both original public policy bodies fatal. Reference contexts restore clones;
compatibility uses only the shared reference helpers and records its reason.
Native successes, errors, compatibility and unexpected reference calls aggregate
across xdist workers. The existing persistent proof session executes each native
request without answer caching; production retains the one-shot helper path.

The focused target passes 81 tests: 35 unchanged firewall-status tests and 46
additions. The same 35 originals pass under the current reference and frozen
starting checkout, `a73ffced33800de9435779a9cabef53864455acb`.
Existing tests and fixtures are unchanged.

Added cases cover epoch and freshness limits, non-finite values, exact types,
clock/reader/arithmetic order, input preservation, opaque identity, provider
interposition, truthiness and partial mutations. A source mutation changes the
native enforced verdict to unverified and fails the unchanged zero-return-code
oracle. Separate controls prove native-only normal oracles, xdist counters and
unset/Bash/Python selector isolation. Transport errors and malformed validity,
state and plan responses remain fatal.

Focused counters record 46 validity, 22 result and 12 plan completions, zero
native errors and zero unexpected reference calls. Sixteen compatibility uses
are counted separately: absolute-value provider three, clock provider four,
wide integer four, state value two, and three other reasons once each.

## Commands and results

```bash
make test-go-dashboard-egress-status-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both commands cross-build for Linux amd64 and arm64 with
CGO disabled. The focused target is included in the bounded Go CI workflow.
Four existing additive startup checks also pass: existing and legacy databases,
corrupt-database recovery and rejection when native storage is unavailable.
Independent correctness and security reviews pass.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 76.05%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 3995 passed | 78.03%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.30%; supplementary combined coverage |

The starting snapshot contains 3716 original tests; the current suite includes
three earlier additions. The full Go matrix adds 276 native boundary cases.
Native counters record 28 validity, 10 result and 174 plan completions, with zero
native errors and zero unexpected reference calls. Sixteen intentional
compatibility uses have the same reason counts as the focused run.

The new adapter covers 130 of 138 executable statements, or 94.20%, in the Go
dataset. Eight provider/constant refusal or reply-validation statements remain
uncovered by that full matrix. The separate union does not pass the Go-only
total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 388 missing of 3362 changed lines; fails | 93%; 218 missing of 3362; passes |
| Frozen starting comparison | 90%; 282 missing of 3021 changed lines; passes | 92%; 214 missing of 3021; passes |

The unchanged gate excludes untracked files before the operator commits them.
A supplementary root-level `diff-cover --include-untracked` run includes the new
adapter: native default/frozen coverage is 88%/90%, with 396/290 missing of
3500/3159 changed statements. Combined default/frozen coverage is 93%/92%, with
226/222 missing of those same totals. Bases and thresholds remain unchanged.

GNU-first topology checks, including new files without exemptions, pass. Python/
YAML lint, scoped Markdown, documentation voice and path checks, operator strings,
file budgets and generated CLI checks pass. File budgets use the frozen starting
comparison; default-base differences remain documented in [PARITY](PARITY.md).

Both reference and Go `make test` attempts stop at the unchanged Markdown gate on
third-party files in ignored dependency caches: 1155 reported errors. Later targets
do not run in those attempts; the dashboard matrices above run separately. The
full required gate remains red. No existing test, check or threshold was weakened.

No image, appliance, fleet or performance proof is claimed for this working tree;
the separate benchmark files remain untouched.
