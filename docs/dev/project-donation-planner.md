# Project donation planner

`service/donation/planner.py` plans routed wall time for an opt-in project
slice without changing the XvB controller or routing any miners.
The feature ships dark. This planner has no I/O and is not called by the
controller yet.

## Provisional policy and owner go-live checklist

The operator accepted these provisional rules on 2026-10-27. The owner must
review all three before enabling the feature:

- Accept XvB durations of zero, a full cycle, or at least `min_dwell_ms` with
  at least 30 seconds left for P2Pool. Reject other durations with `ValueError`
  rather than changing the XvB allocation. With a custom dwell above 30 seconds,
  keep at least that dwell for P2Pool too.
- Use 60 seconds as the debt accrual trigger. It is not a hard slice minimum:
  reserve-trimmed project slices may be shorter when they meet `min_dwell_ms`.
  Defer slices below minimum dwell and carry the unspent debt.
- Measure percentages, debt and segments in routed wall time, including switch
  overhead. `xvb_ms` already includes its overhead. `overhead_ms` does not add
  time, compensate the project allocation or change the debt. These figures
  measure routing time, not hashes accepted after reconnecting.

## Contract

`plan_cycle(xvb_ms, debt_ms, percent, max_fraction, *, cycle_ms=600000,
min_slice_ms=60000, min_dwell_ms=15000, overhead_ms=5000)` returns
`(segments, debt_ms)`. Segments appear in XvB, P2Pool, project order;
zero-length segments are omitted. Durations and timing parameters are integer
milliseconds. Debt may contain fractional milliseconds; percentages are finite
numbers from 0.1 through 10, and `max_fraction` is a finite fraction from 0 through 1.
Debt and overhead must be nonnegative; cycle, trigger and dwell must be positive.
The cycle must fit the P2Pool minimum remainder.

Each cycle credits `percent / 100 * cycle_ms` to debt. Once debt reaches the
trigger, the planner spends as much as the reserve and P2Pool remainder allow,
rounded down to whole milliseconds. The XvB allocation is preserved exactly.
The combined XvB and project allocation cannot exceed `cycle_ms * max_fraction`;
when XvB alone exceeds it, no project time is allocated. Keep at least 30 seconds
(or the custom minimum dwell, if larger) for P2Pool by trimming the project slice.
A full-cycle XvB decision has no P2Pool or project segment.
Unspent debt is capped at three cycles after spending. A sustained reserve
constraint can therefore prevent the requested percentage from being delivered.
Callers must retain returned debt across restarts and config reloads; the
[ledger/API child](https://github.com/p2pool-starter-stack/pithead/issues/3697)
owns persistence.

`sim/project_slice_model.py` exposes `simulate(xvb_schedule, percent,
max_fraction)`. One schedule entry is one cycle. Its result reports total project
milliseconds, project share, destination switches per hour and final debt.
Switches include cycle boundaries and exclude the initial connection.
For 144 ten-minute cycles with room to spare and zero starting debt, the planner
delivers 14, 28 and 72 minutes at 1, 2 and 5 percent respectively. Unspent debt
accounts for the difference from 14.4 and 28.8 minutes; longer runs converge.
At 0.1 percent, 100 cycles (16 hours 40 minutes) accrue the first 60-second slice.
Over a week of 1008 cycles, the planner delivers 600 seconds against a
604.8-second target and carries the remaining 4.8 seconds of debt. The shortfall
is below one 60-second slice.

Run the examples and property tests with the locked test extra:

```bash
cd dashboard
uv run --locked --extra test python -m pytest tests/service/donation
```
