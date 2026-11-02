# XvB forecast and realization parity

Go computes the dashboard's current and forecast tier, current reward per day,
expected wins, measured payout realization, tempered earnings and tier calculator.
The dashboard remains hybrid.

## Native boundary

The overview package preserves insertion order for equal tier thresholds, strict
staleness boundaries, cumulative eligible-tier odds, settled-win attribution and
the delivery prior. Each payout counts once across overlapping win windows.
Integer atomic amounts remain exact until division; the measured rate subtracts
the frozen P2Pool baseline and clamps the result to the reference range.

The calculator sorts tiers stably by threshold and preserves the live, published
and unavailable source labels. The dated published table is used only when XvB
is disabled and no fresh estimate is available. Enabled stale estimates do not
use that table. Realized rewards require live estimates; the unmeasured band uses
the supplied prior. Python supplies existing tier display strings, configuration
constants and explanatory text. Their formatting is not claimed native.

The normal state request computes all seven forecast results in one Go pass
from the existing frozen envelope, using its clock, tiers, estimates, round
statistics, payouts, wins and native earnings coefficient. No new bridge request
or event-loop helper subprocess is added. Python assembles the state response
from those prepared results and captures the untempered summary before applying
the prepared tempered earnings value.

Both bridge phases carry a native-forecast marker. Invalid markers, missing
inputs or missing prepared fields fail the request. The older unmarked private
finish-state format retains its reference builders for compatibility; it is
separate from the marked production path and is not claimed native. Nonfinite
standalone helper results use the existing collision-free marker protocol;
ordinary HTTP JSON retains its prior nonfinite compatibility/error behavior.

## Oracle and supplementary evidence

`make test-go-dashboard-forecast-parity` selects the unchanged XvB forecast,
calculator, expected-wins, realization, tempering, state API and general view
suites with `PITHEAD_IMPL=go` and `TZ=UTC`. The additive forecast adapter layers
over the earnings adapter, makes all seven captured original forecast bodies
fatal, and records successful native calls and unexpected fallback attempts.

The focused target passes 152 tests: 120 unchanged originals and 32 additions.
The same 120 originals pass on the frozen starting checkout and current Python
reference. The frozen baseline is `a73ffced33800de9435779a9cabef53864455acb`.
Native counters record 75 calculator builds, five current-tier selections, 56
current rewards, 55 expected-win calculations, 46 forecast-tier selections, 63
realization calculations, 49 tempered values and two aggregate builds, with zero
unexpected forecast or earnings fallbacks. Separate mutation subprocesses are
excluded from these counters.

The additions compare disabled and stale caches, equal-threshold order, exact
payout sums, overlapping attribution windows, baseline subtraction, rounding,
published/live source labels and immutable inputs. Two source-overlay controls
alter the delivery prior and disable production forecast preparation; each must
break its native oracle. Bridge tests reject malformed markers and incomplete
results, and force concurrent responses to retain their own prepared generation.
Go runtime tests require the frozen clock, settings and payout enablement, reject
missing fields, and consume the native earnings coefficient.

Review reproduced integer-divisor rounding above 2⁵³ in both odds operations.
The raw divisor now reaches the exact integer division helper; two new paired
cases fail before that repair and pass afterward with exact float equality.

The full dashboard snapshot contains 3719 tests: 3716 frozen originals and three
tests added by earlier rounds. Additional native boundary cases supplement that
snapshot; they do not replace its oracle or establish a complete native backend.
Original tests and fixtures remain unchanged.

## Commands and results

```bash
make test-go-dashboard-forecast-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

Checks use locked Python 3.11, Go 1.27.1, UTC and worktree-local offline caches.
Go race tests, vet, module verification and CGO-disabled Linux AMD64/ARM64
cross-builds of both commands pass. Cross-builds do not establish Linux execution.

The full Python reference passes 3719 tests at 83.56% coverage. The final
Go-selected matrix passes 3756 assertions: the same snapshot and 37 native
boundary cases, without A/B calls. Its unchanged total Python coverage gate
fails at 79.06%, below 80%. All original assertions pass, but that is not a
passing full dashboard gate.

Native-only patch coverage passes at 91% against the frozen start (163/1873
lines missing) and fails the required default comparison against `develop` at
87% (269/2214 missing). Combining the measured reference and native datasets
passes the default patch gate at 93% (154/2214 missing), with 96.49% total
coverage; frozen-start paired patch coverage is 91% (150/1873 missing).
Paired coverage is not a Go-only gate pass. The new untracked `go_forecast.py`
has all eighteen executable lines covered; Git diff-based gates must be rerun
after the operator commits it.

Renewed correctness review and security review report no remaining forecast
finding. GNU-first shell, Python, YAML, topology, generated-CLI, file-budget,
path, operator-string and changed-Markdown checks pass without exemptions;
the latter uses the repository's unchanged rules with a private four-file scope.
Both final `make test` attempts pass shell and Python lint, then stop at Markdown
lint on third-party files in local dependency caches. No original gate is weakened.

Python retains base metadata, egress/topology derivation, worker detail builders,
polling, configuration/provider I/O and final state assembly. No new doctor,
Tor/ZMTP probe, benchmark or appliance-host implementation is included.

The current working-tree slice has no committed or fleet proof. No live stack,
appliance deployment, publication or benchmark worktree is changed.
