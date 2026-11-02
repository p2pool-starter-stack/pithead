# Dashboard network policy parity

Go derives dashboard egress posture and topology lists from explicit inputs.
Python retains URL/IP classification, config reads, host attestation and firewall
status, provider calls and HTTP orchestration. This slice adds no network probes.

## Native boundary

The `network` helper separates posture, edge construction and node selection.
Each operation builds a complete ordered list; no per-edge process is created.
Posture classifies selected clearnet paths, firewall blocks, leaks and unknown
routes, preserving the reference counters, labels and field order. The dashboard's
host-network paths retain their distinct firewall treatment.

Topology calls the current posture provider first and retains its summary object.
It then builds ordered edges with the original chosen/blocked/leak flags. Python
supplies the stratum label after formatting the current config value. Explicit
stratum compatibility reuses captured route and port inputs, preserving provider
call counts and formatting order.

Node selection uses only indices, identifiers and zones. Python reconstructs the
result with original nonrelocatable node objects and copied relocatable nodes.
Extra fields and opaque values stay off the wire. Duplicate identifiers, unknown
nodes, list order and per-call list identity retain the reference behavior.
Live config wrappers and all address and URL classifiers remain Python.

The adapter validates response fields and types before returning results. Native
transport failures and invalid responses raise without invoking reference policy.
The main adapter and response validation occupy separate files below 400 lines.

## Explicit compatibility and bounds

Canonical Boolean knobs, known route strings and unchanged route/edge providers
use native policy. Unsupported Boolean/route/source shapes, replaced providers,
changed route/zone constants or node-route vocabulary use reasoned reference
compatibility. Topology still invokes its current posture and node providers in
the original order; its summary is the exact posture summary object.

Node batches accept at most 4096 records. Identifiers, zones and stratum labels
are limited to 256 UTF-8 bytes; lone surrogates retain reference behavior. The
adapter checks the fully JSON-encoded node request, including escaping and newline,
against the 2 MiB native input limit. Oversized or noncanonical node providers use
reference policy. A large escaped-node case proves that the request-size guard
runs before native dispatch. Native errors never trigger compatibility.

Exercised compatibility reasons are Boolean/route shape, route vocabulary,
standby-source shape, replaced XvB and edge providers, graph constants, stratum
port and encoded node-request size. Other eligibility branches are implemented
but are not all independently exercised in the full matrices.

## Oracle and supplementary evidence

The additive plugin makes the three original policy bodies fatal under Go
selection and refreshes captured aliases. Reference comparison contexts restore
clones. Native completions, errors, explicit compatibility and unexpected
reference calls aggregate across xdist workers.

The focused target passes 151 tests: 110 unchanged egress, graph and view tests,
and 41 additions. The same 110 originals pass in current reference mode and the
frozen starting checkout, `a73ffced33800de9435779a9cabef53864455acb`.
An additional selection of 125 unchanged egress/graph/address/firewall tests
passes in both reference checkouts; these selections overlap.

The original exhaustive config sweeps execute every native request. A proof-only
persistent session uses `network-stream` to reuse a Go process per pytest worker,
without caching answers. Production `go_channel` keeps its one-shot helper path.
Both helper modes execute the same request builder and bounded protocol.
Stream tests cover independent requests, malformed-then-valid input, read/write
errors, oversized input, partial replies, deadlines, response-size bounds,
malformed responses, child cleanup, recovery and close. The response cap is checked
before extracting a complete line, including newline-terminated oversized JSON.

Added cases cover provider interposition, input preservation, summary/node identity,
opaque fields, duplicate nodes and native failure boundaries. A source mutation
that removes a `chosen_clearnet` flag fails an unchanged operator-choice oracle. Separate controls
prove xdist aggregation, native-only normal oracles and unset/Bash/Python selector
isolation. Existing tests and fixtures are unchanged.

Focused counters record 49,300 posture, 32,833 edge and 32,847 node operations,
with zero native errors and zero unexpected reference calls. Nine intentional
compatibility cases are counted separately. Mutation and selector subprocesses
are separate controls.

## Commands and results

```bash
make test-go-dashboard-network-parity
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
| Current reference | 3719 passed | 76.89%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 3976 passed | 77.95%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.32%; supplementary combined coverage |

The starting snapshot contains 3716 original tests; the current suite includes
three earlier additions. The full Go matrix adds 257 native boundary cases.
The final newline-terminated reply-cap regression was added afterward and passes
in the final focused target. Native counters record 49,494 posture, 32,926 edge
and 32,938 node completions, nine explicit compatibility uses, zero native errors
and zero unexpected reference calls.

The two new production modules cover 170 of 190 executable statements, or 89.47%,
in the Go dataset: 147/160 in the adapter and 23/30 in response validation.
Twenty compatibility/refusal statements remain uncovered by that full matrix.
The separate union does not pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 363 missing of 3164 changed lines; fails | 93%; 198 missing of 3164; passes |
| Frozen starting comparison | 90%; 257 missing of 2823 changed lines; passes | 93%; 194 missing of 2823; passes |

The unchanged gate excludes untracked files before the operator commits them.
A supplementary root-level `diff-cover --include-untracked` run includes both new
modules: native default/frozen coverage is 88%/90%, with 383/277 missing of
3354/3013 changed statements. Combined default/frozen coverage is 93%/92%, with
218/214 missing of those same totals. Bases and thresholds remain unchanged.

GNU-first topology checks, including new files without exemptions, pass. Python/
YAML lint, scoped Markdown, documentation voice and path checks, operator strings,
file budgets and generated CLI checks pass. File budgets use the frozen starting
comparison; default-base differences remain documented in [PARITY](PARITY.md).

Both reference and Go `make test` attempts stop at the unchanged Markdown gate on
third-party files in ignored dependency caches: 1155 reported errors. Later targets
do not run in those attempts; the dashboard matrices above run separately. The
full required gate remains red. No existing test, check or threshold was weakened.
Independent correctness and security reviews pass after fixing the new test
session's response-size check. No image, appliance, fleet or performance proof is
claimed for this working tree; benchmark files remain untouched.
