import json
import time

from mining_dashboard.config import config

STATUS_PATH = "/control/results/egress-status.json"
CHECK_INTERVAL_S = 120
_MAX_EPOCH_S = 2**53
ENFORCED, MISSING, UNVERIFIED = "enforced", "missing", "unverified"
_MISSING_RCS = {1, 2, 4, 5}
_LABELS = {
    MISSING: "Tor-only egress firewall MISSING on the host (clearnet egress is not fail-closed; "
    "run 'pithead up')",
    UNVERIFIED: "Egress firewall state unverified",
}

WATCHDOG_CLEAN, WATCHDOG_LEAKING, WATCHDOG_NOT_OBSERVED = "clean", "leaking", "not-observed"

def egress_firewall_state(path=None, now=None):
    try:
        with open(path or STATUS_PATH, encoding="utf-8") as f:
            status = json.load(f)
    except (OSError, ValueError, RecursionError):
        return UNVERIFIED
    rc = status.get("rc") if isinstance(status, dict) else None
    checked_at = status.get("checked_at") if isinstance(status, dict) else None
    if type(rc) is not int or type(checked_at) not in (int, float):
        return UNVERIFIED
    if not -_MAX_EPOCH_S <= checked_at <= _MAX_EPOCH_S:
        return UNVERIFIED
    now = time.time() if now is None else now
    if abs(now - checked_at) > 3 * CHECK_INTERVAL_S:
        return UNVERIFIED
    if rc == 0:
        return ENFORCED
    return MISSING if rc in _MISSING_RCS else UNVERIFIED


def live_firewall_state():
    return egress_firewall_state() if config.TOR_EGRESS_FIREWALL else None


def watchdog_verdict(path=None):
    try:
        with open(path or STATUS_PATH, encoding="utf-8") as f:
            status = json.load(f)
    except (OSError, ValueError, RecursionError):
        return WATCHDOG_NOT_OBSERVED
    if not isinstance(status, dict):
        return WATCHDOG_NOT_OBSERVED
    ha = status.get("host_audit")
    if not isinstance(ha, dict):
        return WATCHDOG_NOT_OBSERVED
    wd = ha.get("watchdog")
    if wd in (WATCHDOG_CLEAN, WATCHDOG_LEAKING):
        return wd
    return WATCHDOG_NOT_OBSERVED


def live_watchdog_verdict():
    return watchdog_verdict() if config.TOR_EGRESS_FIREWALL else None


def with_firewall_state(build, *, firewall, state=None, **knobs):
    if not firewall:
        return build(firewall=False, **knobs)
    state = state or egress_firewall_state()
    result = build(firewall=state == ENFORCED, **knobs)
    summary = result["summary"]
    summary["firewall_state"] = state
    if state != ENFORCED:
        summary["level"] = "warn"
        summary["label"] = f"{_LABELS[state]}; {summary['label']}"
    return result
