from dataclasses import dataclass

from mining_dashboard.config.config import XVB_TIME_ALGO_MS
from mining_dashboard.service.donation.planner import plan_cycle


@dataclass(frozen=True)
class Result:
    project_ms: int
    project_share: float
    switches_per_hour: float
    debt_ms: float


def simulate(xvb_schedule, percent, max_fraction, *, debt_ms=0, cycle_ms=XVB_TIME_ALGO_MS):
    project_ms = 0
    switches = 0
    cycles = 0
    previous = None
    for xvb_ms in xvb_schedule:
        segments, debt_ms = plan_cycle(xvb_ms, debt_ms, percent, max_fraction, cycle_ms=cycle_ms)
        for destination, duration in segments:
            if previous is not None and previous != destination:
                switches += 1
            previous = destination
            if destination == "project":
                project_ms += duration
        cycles += 1
    elapsed_ms = cycles * cycle_ms
    return Result(
        project_ms=project_ms,
        project_share=project_ms / elapsed_ms if elapsed_ms else 0,
        switches_per_hour=switches * 3_600_000 / elapsed_ms if elapsed_ms else 0,
        debt_ms=debt_ms,
    )
