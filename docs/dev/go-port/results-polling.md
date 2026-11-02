# Worker polling parity

Go now owns thirteen worker-poll operations: proxy row normalization, summary
parsing and retention, direct-result merging, rate aggregation, reset-safe share
and counter deltas, lifecycle tracking, probe eligibility and probe completion.
Python retains the poll loop, cache expiry, clocks, async requests, storage
callbacks and RigForge feed parsing. This does not establish a fully native
dashboard or polling loop.

## Native boundary

Proxy positional and legacy rows retain their separate windows and units.
Truncated rows are skipped, successful empty responses clear the cache and an
unusable response preserves the last good snapshot through the existing caller.
The missing-workers error for a nonempty object remains a native `ValueError`.
Valid zero summary counters replace previous values; invalid bodies retain the
same last-good object. Counter restarts rebaseline without backfilling history.
Integer arithmetic preserves wide counters; floating operations use binary float
arithmetic, including fractional scaling and nonfinite hashrate transport.

Direct-result plans contain only assigned fields. Python applies those patches
to the original worker dictionaries, preserving unrelated nested objects and
row/result identity. The existing `parse_rigforge` callback supplies the parsed,
credential-filtered block; it is outside the native claim. Skipped, failed and
successful probes retain their distinct badges and direct-rate behavior.

Lifecycle operations return ordered patches, live indices and state records.
Reconnects restart inferred uptime; positive direct uptime remains authoritative.
Aged-out offline workers retain their last-active state while the proxy reports
them, preventing a ghost from returning on the next poll. Nil and empty names
are distinct, and repeated worker names share connection state. Indexed names
and answered pairs keep this work linear in fleet size; a 12000-row regression
exercises the former repeated-scan path without making a performance claim.

Probe policy freezes name, address and status before its first await. Go chooses
eligible workers and the result indices; Python executes `asyncio.gather` and
returns the original response objects. Successful answers alone populate the
next `(name, address)` set. A failed helper, bad plan, bad completion or request
exception does not replace that set. The existing `XMRigWorkerClient` SSRF guard
still validates every request target; worker names never become hosts.

Native helper failures do not call a Python reference operation. Reply validation
precedes applying patches or replacing lifecycle/probe state. Native probe
helpers run outside the event loop, with a forced interleaving proving that a
changed live worker cannot change the captured request target or answered pair.
Public unset, Bash and Python selection retain the reference functions; only
the Go child explicitly installs this adapter.

Supported lifecycle keys are strings or nil; probe names and addresses are
strings. Counters and lifecycle timestamps must be valid numeric service values.
Malformed service shapes, nonfinite counter comparisons, nonfinite lifecycle
clocks and integer-to-float overflow fail closed. The boundary accepts JSON
service shapes; Python-only container distinctions and exact exception classes
outside that boundary are not claimed. Non-JSON test doubles can fail before
the helper starts; those errors are counted separately from native successes.

## Oracle and supplementary evidence

The focused target runs the unchanged data-helper, worker-probe, liveness and
DataService suites under `PITHEAD_IMPL=go`. Its additive adapter makes all ten
ported helper bodies and both class methods fatal, including imported aliases,
and records native successes, errors and unexpected fallback attempts.

The focused target passes 336 tests: 272 unchanged originals and 64 additions.
Those originals also pass on the frozen starting checkout and current reference.
Counters record 972 successful calls across all thirteen operations, with zero
unexpected fallbacks. Three missing-workers cases produce native `ValueError`;
131 non-JSON test-double inputs produce counted transport `TypeError` failures.
Explicit helper replacement and mutation subprocesses are separate controls.

Paired cases cover thresholds, defaults, units, failed APIs, wide integers,
binary float operations, nonfinite rates, lifecycle state and object identity.
Runtime cases check malformed replies, failure atomicity, off-loop execution
and immutable probe targets. Two source-overlay mutations independently change
stale-worker retention and offline-probe eligibility; each breaks an unchanged
original test. Three selection sentinels prove reference modes never launch the
native polling helper.

Early DataService imports exposed imported earnings aliases in the existing
additive adapter. That adapter now replaces the Telegram formatter aliases too,
while preserving its fatal original bodies. An ownership regression and the
unchanged formatting suites cover this import order.

The numeric comparisons also reproduce three failures on the earlier binary for
float `1e23` versus integer `10**23`. The corrected decoder preserves binary
float ordering before deciding a reset or baseline; the same cases then pass.

The frozen starting oracle remains
`a73ffced33800de9435779a9cabef53864455acb`. Original tests, fixtures and check
thresholds are unchanged. New cases under `tests/go-parity/` and Go units are
supplementary evidence.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 82.36%; total gate passes |
| Go selection with storage/native-body adapters | 3801 passed | 78.28%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.53%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three tests from earlier
rounds. The Go matrix adds 82 native boundary cases without running paired
reference comparisons. Combined coverage measures retained Python reference
paths too; it does not make the Go-only total gate pass.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 271 missing of 2312 changed lines; fails | 93%; 156 missing of 2312; passes |
| Frozen starting comparison | 91%; 165 missing of 1971 changed lines; passes | 92%; 152 missing of 1971; passes |

The diff gates omit the new untracked polling module until the operator commits
it. Both XML datasets independently measure 90 of its 94 executable statements;
four malformed-reply rejection statements remain uncovered by these matrices.
The patch gates must run again after the commit. The existing comparison bases
and thresholds are unchanged.

## Commands and results

```bash
make test-go-dashboard-polling-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. The CLI and dashboard cross-build for Linux amd64 and
arm64 with CGO disabled. The bounded CI job includes the focused target. Python/YAML
lint, documentation voice and path checks, operator strings, file budgets,
generated CLI checks and GNU-first topology checks pass. The topology scan also
includes new files without exemptions. Changed Markdown passes the repository
rules separately. Independent correctness and security reviews pass on the
supported boundary.
File-budget checks use the documented frozen-start override; the existing
default-base differences remain recorded in [PARITY](PARITY.md).

Both reference and Go `make test` attempts stop at the unchanged Markdown gate
on third-party files inside the local dependency caches. Neither attempt reaches
later targets. The separately run dashboard matrices above provide assertion and
coverage evidence; the required full gate remains red. No existing check or
threshold was weakened.

The dashboard image copies the complete backend package, so its existing build
includes the new adapter. Image execution and fleet proof for this slice remain
pending.

Checks use locked Python 3.11, Go 1.27.1, UTC and worktree-local offline caches.
No benchmark files, live stack or fleet are changed. This working-tree slice
has no committed or fleet proof. Remaining state metadata, network scheduling,
cache timing and provider I/O stay Python.
