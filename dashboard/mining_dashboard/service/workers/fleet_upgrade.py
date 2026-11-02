import json
import os
import uuid

from mining_dashboard.client.rigforge_freshness import feed_stale
from mining_dashboard.config import config
from mining_dashboard.service import request_spool
from mining_dashboard.service.health.update_checker import compute_update, parse_semver

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
    tag = (release or {}).get("tag")
    out = {"version": tag, "eligible": [], "skipped": []}
    if not tag:
        return out
    for w in sorted(workers, key=lambda x: x.get("name", "")):
        name = w.get("name")
        rigforge = w.get("rigforge")
        if not name or not (isinstance(rigforge, dict) or w.get("adopted")):
            continue
        version = None if feed_stale(rigforge) else (rigforge or {}).get("version")
        if version and parse_semver(version) and not compute_update(version, tag, None):
            continue
        if not version:
            reason = "offline or telemetry unavailable — version unknown"
        elif not parse_semver(version):
            reason = "reports an unrecognised RigForge version"
        elif w.get("status") != "online":
            reason = "offline"
        elif not w.get("adopted"):
            reason = "not managed by this stack — adopt it first"
        elif w.get("api_ok") is False:
            reason = "control API unreachable"
        else:
            out["eligible"].append({"name": name, "running": version})
            continue
        out["skipped"].append({"name": name, "reason": reason})
    return out


def summary_text(res):
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
    stamped = []
    try:
        for entry in os.scandir(config.CONTROL_RESULTS_DIR):
            try:
                if entry.name.endswith(".json"):
                    stamped.append((entry.stat().st_mtime, entry))
            except OSError:
                continue
    except OSError:
        return None
    stamped.sort(key=lambda item: item[0], reverse=True)
    for _, entry in stamped[:_LATEST_SCAN]:
        try:
            with open(entry.path) as f:
                res = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(res, dict) and res.get("action") == action:
            return {"id": entry.name[:-5], **res}
    return None
