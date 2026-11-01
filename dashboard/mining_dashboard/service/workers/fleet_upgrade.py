import json
import os
import uuid

from mining_dashboard.client.rigforge_freshness import feed_stale
from mining_dashboard.config import config
from mining_dashboard.service import request_spool
from mining_dashboard.service.health.update_checker import compute_update

_LATEST_SCAN = 25

RUNNING = "running"
SETTLED_WORDS = {
    "applied": "upgraded",
    "noop": "already current",
    "throttled": "retry later",
    "accepted": "still running on the rig",
    "rolled_back": "rolled back",
    "rejected": "rejected",
    "failed": "failed",
    "not_started": "not started",
}


def plan(workers, release):
    """Which rigs an Update all would touch: ``{version, eligible, skipped}``. A rig already on
    the release, or one that reports no RigForge block, is left out of both lists."""
    tag = (release or {}).get("tag")
    out = {"version": tag, "eligible": [], "skipped": []}
    if not tag:
        return out
    for w in sorted(workers, key=lambda x: x.get("name", "")):
        name = w.get("name")
        rigforge = w.get("rigforge")
        if not name or not isinstance(rigforge, dict):
            continue
        reason = None
        if w.get("status") != "online" or feed_stale(rigforge):
            reason = "offline or telemetry unavailable — version unknown"
        elif not w.get("adopted"):
            reason = "not managed by this stack — adopt it first"
        elif w.get("api_ok") is False:
            reason = "control API unreachable"
        elif not rigforge.get("version"):
            reason = "reports no RigForge version"
        elif not compute_update(rigforge["version"], tag, None):
            continue
        if reason:
            out["skipped"].append({"name": name, "reason": reason})
        else:
            out["eligible"].append({"name": name, "running": rigforge["version"]})
    return out


def summary_text(res):
    """The one Telegram line for a settled run."""
    rigs = res.get("rigs") or []
    counts = {}
    for rig in rigs:
        counts[rig.get("status")] = counts.get(rig.get("status"), 0) + 1
    parts = [f"{n} {SETTLED_WORDS.get(s, s)}" for s, n in counts.items()]
    head = f"\U0001f504 Update all rigs to {res.get('version')}: {len(rigs)} rig(s) — "
    lines = [head + ", ".join(parts) + "."]
    lines += [
        f"• {r['name']}: {SETTLED_WORDS.get(r['status'], r['status'])}"
        + (f" ({r['reason']})" if r.get("reason") else "")
        for r in rigs
        if r.get("status") not in ("applied", "noop")
    ]
    return "\n".join(lines)


def submit_worker_upgrade_all(workers, version, actor="", intent_id=None):
    rid = str(uuid.UUID(intent_id)) if intent_id else str(uuid.uuid4())
    request = {
        "id": rid,
        "action": "worker-upgrade-all",
        "actor": actor,
        "workers": list(workers),
        "version": version,
    }
    return request_spool.write(request)


def latest_result(action) -> dict | None:
    """The newest result whose ``action`` field is ``action``, or None. Scans the newest few
    results only: the host prunes the directory by age and count."""
    try:
        entries = sorted(
            (e for e in os.scandir(config.CONTROL_RESULTS_DIR) if e.name.endswith(".json")),
            key=lambda e: e.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        return None
    for entry in entries[:_LATEST_SCAN]:
        try:
            with open(entry.path) as f:
                res = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(res, dict) and res.get("action") == action:
            return {"id": entry.name[:-5], **res}
    return None
