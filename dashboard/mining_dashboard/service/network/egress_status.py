"""The Tor-only egress firewall's live state on the host (#2599).

The dashboard cannot read host netfilter, so ``network.tor_egress_firewall`` only says the firewall
is *configured*. ``pithead-egress.timer`` runs ``pithead egress-status`` every two minutes, which
writes the doctor's ``tor_egress_enforced`` verdict to ``egress-status.json`` in the read-only
control results mount. This module reads it and applies it to the egress posture.

* rc 0 → ``enforced``: the configured backstop is live.
* rc 1, 2, 4, 5 → ``missing``: absent, no tool, orphaned chain, or shadowed. Not fail-closed.
* rc 3, no file, a malformed file, or a check older than three intervals → ``unverified``. An
  install whose ``up`` has not yet installed the timer must neither alarm nor show green.
"""

import json
import os
import time

from mining_dashboard.config import config

EGRESS_STATUS_PATH = os.environ.get("EGRESS_STATUS_PATH", "/control/results/egress-status.json")
CHECK_INTERVAL_S = 120  # pithead-egress.timer's OnUnitActiveSec
ENFORCED, MISSING, UNVERIFIED = "enforced", "missing", "unverified"
_MISSING_RCS = {1, 2, 4, 5}
_LABELS = {
    MISSING: "Tor-only egress firewall MISSING on the host (clearnet egress is not fail-closed; "
    "run 'pithead up')",
    UNVERIFIED: "Egress firewall state unverified",
}


def egress_firewall_state(path=None, now=None):
    """``enforced`` / ``missing`` / ``unverified`` from the host's status file."""
    try:
        with open(path or EGRESS_STATUS_PATH, encoding="utf-8") as f:
            status = json.load(f)
        rc, checked_at = int(status["rc"]), float(status["checked_at"])
    except (OSError, ValueError, TypeError, KeyError):
        return UNVERIFIED
    now = time.time() if now is None else now
    if abs(now - checked_at) > 3 * CHECK_INTERVAL_S:
        return UNVERIFIED
    if rc == 0:
        return ENFORCED
    return MISSING if rc in _MISSING_RCS else UNVERIFIED


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
