"""The Tor-only egress firewall's live state on the host (#2599).

The dashboard cannot read host netfilter, so ``network.tor_egress_firewall`` only says the firewall
is *configured*. ``pithead-egress.timer`` runs ``pithead egress-status`` every two minutes, which
writes the doctor's ``tor_egress_enforced`` verdict to ``egress-status.json`` in the read-only
control results mount. This module reads it and applies it to the egress posture.

* rc 0 → ``enforced``: the configured backstop is live.
* rc 1, 2, 4, 5 → ``missing``: absent, no tool, orphaned chain, or shadowed. Not fail-closed.
* rc 3, no file, a malformed file, or a check older than three intervals → ``unverified``. An
  install whose ``up`` has not yet installed the timer must neither alarm nor show green.

The file is typed on read, never coerced: ``rc`` must be a JSON integer and ``checked_at`` a finite
JSON number. ``json`` accepts ``NaN`` and ``Infinity``, and Python treats ``False`` as ``0``, so a
bare ``int()``/``float()`` would read ``{"rc": false}`` as enforced. A JSON integer is also
unbounded, and turning 400 digits into a float raises ``OverflowError``, so ``checked_at`` is range
checked before any arithmetic: comparing an int with a float is exact in Python and never
overflows, and NaN and the infinities fail the same range. Deep nesting makes ``json`` raise
``RecursionError``, which reads unverified like any other unparseable file.
"""

import json
import time

from mining_dashboard.config import config

STATUS_PATH = "/control/results/egress-status.json"  # the read-only control results mount
CHECK_INTERVAL_S = 120  # pithead-egress.timer's OnUnitActiveSec
_MAX_EPOCH_S = 2**53  # past any real clock, and every integer below it is an exact float
ENFORCED, MISSING, UNVERIFIED = "enforced", "missing", "unverified"
_MISSING_RCS = {1, 2, 4, 5}
_LABELS = {
    MISSING: "Tor-only egress firewall MISSING on the host (clearnet egress is not fail-closed; "
    "run 'pithead up')",
    UNVERIFIED: "Egress firewall state unverified",
}


def _fresh_status(path, now) -> dict | None:
    try:
        with open(path or STATUS_PATH, encoding="utf-8") as f:
            status = json.load(f)
    except (OSError, ValueError, RecursionError):
        return None
    checked_at = status.get("checked_at") if isinstance(status, dict) else None
    if type(checked_at) not in (int, float) or not -_MAX_EPOCH_S <= checked_at <= _MAX_EPOCH_S:
        return None
    now = time.time() if now is None else now
    return status if abs(now - checked_at) <= 3 * CHECK_INTERVAL_S else None


def egress_firewall_state(path=None, now=None):
    """``enforced`` / ``missing`` / ``unverified`` from the host's status file."""
    status = _fresh_status(path, now)
    rc = status.get("rc") if status else None
    if type(rc) is not int:
        return UNVERIFIED
    if rc == 0:
        return ENFORCED
    return MISSING if rc in _MISSING_RCS else UNVERIFIED


_UNMONITORED = {
    "loaded": False,
    "would_drop": 0,
    "counters": [],
    "host_violations": 0,
    "unmonitored": True,
}


def host_audit_state(path=None, now=None):
    """The host audit table's counters from the same status file, or the unmonitored shape."""
    status = _fresh_status(path, now)
    audit = status.get("host_audit") if status else None
    if not isinstance(audit, dict) or audit.get("verdict") != "present":
        return {**_UNMONITORED, "counters": []}
    would_drop, counters = audit.get("would_drop"), audit.get("counters")
    if type(would_drop) is not int or would_drop < 0 or not isinstance(counters, list):
        return {**_UNMONITORED, "counters": []}
    return {
        "loaded": True,
        "would_drop": would_drop,
        "counters": [
            {"packets": c["packets"], "bytes": c["bytes"]}
            for c in counters
            if isinstance(c, dict) and type(c.get("packets")) is int and type(c.get("bytes")) is int
        ],
        "host_violations": would_drop,
        "unmonitored": False,
    }


def live_firewall_state():
    """The state to act on, or None when the operator opted out of the firewall."""
    return egress_firewall_state() if config.TOR_EGRESS_FIREWALL else None


def with_firewall_state(build, *, firewall, state=None, **knobs):
    """Run a posture/topology builder against the firewall as it IS, not as configured.

    Only a verified firewall marks clearnet routes "blocked"; otherwise the summary warns and
    leads with the firewall's state. ``state`` is injectable for tests."""
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
