# Worker detail parity

Go builds the Worker Inspect payload, config-origin verdict, config drift,
unsettled-apply predicate and worker hashrate history. Python retains provider
I/O, the existing SQL queries and HTTP orchestration; the backend remains hybrid.

## Native boundary

The fleet package selects the observed worker, formats telemetry and version
history, builds the RigForge display/update fields, sorts writable keys and
assembles the twenty-field payload. Editable state uses the operator's pinned
host; the displayed IP remains the proxy/miner observation. Missing workers,
unread history, a failed scoped change lookup and a genuine lookup miss retain
their separate meanings. Only a known applied change can be attributed here;
rolled-back, failed, pending and unknown outcomes retain their original verdicts.

Drift strips credentials from both sides at the original depth limit, compares
only keys present on both sides and suppresses comparison only for the newest
unsettled apply. Explicit null differs from an absent field. Numeric and string
canonicalization, boolean tags, recursive raw equality and wide integer
comparison match the Python operations. Decimal strings use the existing pinned
Python 3.11 Unicode digit table, reject hexadecimal syntax and preserve overflow
to infinity. Canonical integer conversion outside float range fails closed;
the Python reference raises `OverflowError`, while the private native transport
reports a native failure. Exact exception-class parity for that unsupported
boundary is not claimed. The same bound applies to hashrate integer formatting;
oversized values fail instead of rendering a successful zero.
Raw NaN drift comparisons also fail closed: Python container equality can depend
on float-object identity, which this JSON boundary does not preserve. Nonfinite
chart values and markers are supported without an encoding round-trip; nonfinite
gauge downsampling above 700 rows remains unsupported and fails closed.

Hashrate history reuses the native gauge/filter operations for the selected
range or explicit window, with the same bounds for apply and upgrade markers.
Integer marker timestamps retain exact millisecond multiplication. Zero, false
and absent history timestamps keep the worker payload's empty display label.
Python retains the scalar `_comparable` helper for direct reference callers and
the metadata parser; neither runs inside the native drift/provenance operation.

On the normal Go-selected HTTP path, Python freezes only the timestamp, release
metadata and selected worker on the event loop. Provider reads, bounded native
helper execution and result validation then run in one background call. A queued
request retains that captured clock and worker even if the live generation
changes. Unrelated workers, shares and system data do not enter the helper.
Explicit caller/test interpositions of the public builder retain their existing
synchronous call boundary. They are separate from the normal native path.

The helper uses an opt-in success envelope; existing fleet callers retain their
raw JSON protocol. Native failures never execute a reference builder. The Python
adapter validates the exact key set, booleans, lists, nullable fields and chart
shape before accepting a successful helper reply. The public Bash/Python/unset
selection modes retain the reference builder without invoking a native helper.
The opt-in fleet envelope carries the existing collision-free nonfinite marker
through decoding and result encoding. Infinite/NaN headline hashrates, infinite
config comparisons and nonfinite passthrough fields have paired coverage.

## Oracle and supplementary evidence

`make test-go-dashboard-worker-detail-parity` runs the unchanged worker inspect,
IP, metadata, freshness, credential, drift, general view and client metadata
suites with `PITHEAD_IMPL=go` and UTC. The additive adapter makes all five ported
original bodies fatal, including imported aliases, and records native successes,
expected protocol failures and unexpected fallback attempts.

The focused target passes 274 tests: 196 unchanged originals and 78 new paired,
boundary, selection and source-mutation cases. The same 196 originals pass on
the frozen starting checkout and current Python reference. The baseline remains
`a73ffced33800de9435779a9cabef53864455acb`; no original test or fixture changes.
Native counters record 89 complete payload builds, 151 origin verdicts, 44 drift
checks, sixteen unsettled predicates and three history builds, with zero unexpected
fallbacks. Nine expected native errors come from explicit malformed-input,
integer-overflow and NaN-identity boundaries. Mutation subprocesses are excluded.

Two source-overlay controls disable drift detection and the complete native
payload builder independently; each must break its oracle. Added numeric cases
reproduce five failures on the earlier binary for hexadecimal, overflow and
Unicode strings, then pass after the parser repair. Other comparisons cover
credentials, nested values, scoped lookup status, host versus observed IP,
custom chart windows, marker types, display labels and integer precision.

Runtime checks block a provider read and require it to run outside the event
loop, then change the live worker and clock before allowing the helper to run.
The response must still contain the old worker and a fresh old-generation agent
report. An unrelated-data object that refuses copying proves the selected-worker
envelope excludes the rest of the fleet. Full-key wrong-type helper replies,
missing fields and helper failures are rejected without fallback.

The full dashboard snapshot contains 3719 tests: 3716 frozen originals and three
tests added by earlier rounds. Supplementary cases are reported separately;
passing assertions do not override the unchanged coverage gates.

| Run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 83.06%; total gate passes |
| Go selection, storage and native-body adapters | 3784 passed: 3719 snapshot tests plus 65 native boundary cases | 78.57%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.52%; supplementary combined coverage |

The Go matrix contains no paired reference executions. Its 65 added cases cover
native ownership, invalid replies and failures; the reference implementations of
the claimed operations remain fatal. The combined dataset measures retained
reference paths as well, and does not turn the Go-only total gate green.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 87%; 270 missing of 2245 changed lines; fails | 93%; 155 missing of 2245; passes |
| Frozen starting comparison | 91%; 164 missing of 1904 changed lines; passes | 92%; 151 missing of 1904; passes |

Diff coverage omits the new untracked adapter until the operator commits it.
Both XML datasets independently measure 59 of its 60 executable statements;
the missing statement is the standalone history wrapper, exercised by the
separate focused target. The patch gates must run again after that commit.
The existing comparison bases and thresholds are unchanged.

## Commands and results

```bash
make test-go-dashboard-worker-detail-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both CLI and dashboard also cross-build for Linux amd64
and arm64 with CGO disabled. The bounded CI job includes the focused target.
Python lint, YAML, documentation voice/path references, operator strings,
file budgets and generated CLI checks pass. GNU-first topology checks pass for
tracked and new files without exemptions. Markdown lint passes on the four
changed documentation files with the repository rules.

Both reference and Go `make test` attempts stop at the unchanged Markdown gate:
it includes third-party Markdown inside the local dependency caches. Neither
attempt reaches later targets. The separately run dashboard matrices above
provide assertion and coverage evidence; the required full gate remains red.
Independent correctness and security reviews found no remaining issue in the
supported worker-detail boundary.

Checks use locked Python 3.11, Go 1.27.1, UTC and worktree-local offline caches.
No benchmark files or live stack are changed. This working-tree slice has no
committed or fleet proof. Polling, remaining state metadata and provider I/O stay
Python; complete native dashboard parity is still in progress.
