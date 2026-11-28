import hashlib
import time

from mining_dashboard.client import xmrig_client
from mining_dashboard.service import audit_service


def _credential_key(name, rig_id):
    entry = xmrig_client._worker_override(name.split("+")[0].strip(), None, rig_id) or {}
    token = entry.get("read_token")
    return hashlib.sha256(token.encode()).hexdigest()[:16] if token else None


def _fingerprint(rigforge):
    hints = xmrig_client._feed_identity(rigforge.get("identity"))
    return tuple(sorted(hints.items())) if hints else None


async def observe_poll(svc, workers, results, now=None):
    now = time.time() if now is None else now
    tracker = svc._identity
    tracker.sweep(now)
    for w, extra in zip(workers, results, strict=False):
        rf = (extra or {}).get("rigforge")
        rig_id = xmrig_client._feed_rig_id(extra) if extra and extra.get("api_ok") else None
        if not rig_id or w.get("status") != "online" or not isinstance(rf, dict):
            continue
        name = w.get("name") or ""
        moved = tracker.observe(
            rig_id, w.get("ip"), _fingerprint(rf), _credential_key(name, rig_id), now
        )
        if moved:
            await svc._record_audit_event(
                "rig-identity",
                name,
                "moved-hardware",
                "info",
                f"rig id {rig_id} reports different hardware hints from {w.get('ip')}",
                event_id=audit_service.build_event_id(
                    "rig-moved", rig_id, w.get("ip"), repr(_fingerprint(rf))
                ),
            )
