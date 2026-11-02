# Earnings and confirmed payout parity

Go builds the dashboard's earnings calculator, confirmed payout rollups and
expected-versus-actual summary. The backend remains hybrid.

## Native boundary

The overview package implements the Monero and Tari per-hash rates, Tari
time-to-block coefficient, previous local-day boundaries, confirmed payout totals,
`build_earnings` and `build_earnings_vs_actual`. Disabled confirmation stays
distinct from an enabled wallet with no payouts. Window lower bounds, future
timestamps, half-open yesterday boundaries, oldest/last positive timestamps,
partial-history flags and wallet-status overrides match the Python contract.

Integer payout sums stay exact until division. A floating amount promotes the
accumulator at the same point as Python, preserving sequential rounding and the
distinction between integer and floating divisors. Summary percentages use
ties-to-even rounding and retain the original 999-percent withholding rule.
Tari locality remains tri-state. The previous-day calculation follows the
reference's noon probe and local-midnight normalization, including DST transitions,
midnight gaps and skipped calendar dates.

For normal `/api/state` requests, Go computes the base earnings section from the
already-frozen snapshot's payout rows, enable flags, clock and timezone. No extra
payout-history copy crosses the bridge, and no synchronous helper process is
added to the Python event loop. Python uses that prepared base while retaining
its existing XvB forecast, realization and tempering logic. It captures the
summary inputs before tempering; Go completes the summary after the bridge POST.

Both request phases carry an explicit native-earnings marker. Marked requests
require the prepared result; malformed markers or missing results fail. The
older unmarked private finish-state format retains its reference builders for
compatibility with existing callers. It is separate from the normal marked
production path and is not claimed native.

The additive helper adapter uses a collision-free per-request marker to transport
nonfinite numeric results, including overflow at subnormal difficulty. Unmarked
HTTP JSON transport retains its prior compatibility/error behavior for nonfinite
payloads; this slice does not claim those HTTP responses native. Python also
retains polling, remaining state metadata, worker detail builders and the XvB
calculator's forecast/provider operations.

## Oracle and supplementary evidence

`test-go-dashboard-earnings-parity` selects the unchanged earnings service,
numeric-property, earnings-view, state API, general view and Telegram formatter
suites under `TZ=UTC`. The new
`dashboard_earnings_plugin.py` layers over the existing native adapters, replaces
all seven earnings operations and makes their captured original bodies fatal.
It records native successes and unexpected fallback attempts.

The new comparisons cover wide integer and mixed floating sums, divisor kinds,
disabled/empty payouts, wallet overlays, missing/zero/future timestamps, the
percentage cutoff and immutable summary inputs. Timezone cases cover Chicago's
23/25-hour days, a São Paulo midnight gap and Apia's skipped date; each restores
the Python process timezone. Bridge cases reject invalid native markers and
missing prepared results.

Two source-overlay controls change the scalar rate and the production earnings
preparation separately. Each must make its unchanged numeric or native-ownership
HTTP assertion fail. The HTTP control reaches the fatal reference body rather
than passing through a hidden fallback. Go runtime tests also force a poll
generation change between GET and POST and require the first payout generation.

The final focused target passes 243 tests: 209 unchanged originals and 34 new
cases. The same 209 originals pass on both the frozen starting checkout and the
current Python reference, with the same UTC fixture. Native counters record
54 calculator builds, 62 summaries, 22 payout rollups, nine local-day operations,
five Tari time-to-block coefficients, 626 Monero rates and 22 Tari rates, with zero unexpected
fallbacks. Counts exclude xdist workers and separate mutation subprocesses.

The full dashboard snapshot contains 3719 tests: 3716 frozen original tests and
three tests added by earlier port rounds. New comparison, boundary and mutation
cases are supplementary evidence. No original suite or fixture is edited; the
freeze audit compares against `a73ffced33800de9435779a9cabef53864455acb`.

## Commands and results

```bash
make test-go-dashboard-earnings-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

Runs use locked Python 3.11, Go 1.27.1 and worktree-local offline caches. Full
reference and Go-selected dashboard runs retain the unchanged coverage gates;
paired reference/native coverage is reported separately from Go-only coverage.
The full reference passes 3719 tests at 83.63% coverage. Go race tests, vet,
module verification and CGO-disabled Linux AMD64/ARM64 cross-builds of both
commands pass. Cross-builds do not establish Linux execution. Source review and
GNU-first shell, Python, YAML, topology, generated-CLI, file-budget, path,
operator-string and changed-Markdown checks pass without exemptions.

The final Go-selected matrix passes 3745 assertions: the 3719 snapshot tests
and 26 native boundary cases, without A/B oracle calls. Its unchanged 80% total
Python coverage gate fails at 79.27%. Native-only patch coverage passes at 91%
against the frozen starting commit (162/1857 lines missing), but the required
default comparison against `develop` fails at 87% (268/2197 missing). Combining
the measured reference and native datasets passes the default patch gate at 92%
(154/2197 missing), with 96.48% total coverage; the frozen-start paired patch
result is 91% (150/1857 missing). Paired coverage is not a Go-only gate pass.
The new untracked `go_earnings.py` measures all twelve executable lines covered;
Git diff-based gates must be rerun after the operator commits the new files.

The host-default Go matrix encountered a DST-sensitive assertion in the unchanged
Telegram formatter suite: on the 25-hour local day, subtracting 48 elapsed hours
lands inside yesterday. The isolated Python reference fails identically. Both
affected files pass 95 tests in each mode with `TZ=UTC` from process start; the
final paired full matrices use that same controlled timezone. No oracle is
edited to change the calendar expectation.

Full `make test` attempts in reference and Go modes still stop at Markdown lint
on third-party local-cache files. No check is weakened to skip those files.

Fleet submission for the preceding committed shipping round was unavailable:
its exact SHA was not present on origin when checked. No job was submitted. The
current working-tree earnings changes have no committed or fleet proof. No live
stack, appliance deployment, publication or benchmark worktree is changed.
