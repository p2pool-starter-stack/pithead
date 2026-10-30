import json
import re
from pathlib import Path

_FIELDS = ("recipient", "project_address", "endpoint", "kind", "tls_fingerprint")


def load_destination(path: Path | None = None) -> dict:
    try:
        data = json.loads(
            (Path(__file__).with_name("donation.json") if path is None else path).read_text(
                encoding="utf-8"
            )
        )
    except (OSError, ValueError):
        return {"available": False, "reason": "donation file is unreadable or invalid"}
    if not isinstance(data, dict):
        return {"available": False, "reason": "donation file must be an object"}
    for field in _FIELDS:
        if field == "tls_fingerprint" and field not in data:
            continue
        if not isinstance(data.get(field), str):
            return {"available": False, "reason": f"{field} must be a string"}
    recipient = data["recipient"]
    if not recipient.strip() or len(recipient) > 40 or any(ord(c) < 32 for c in recipient):
        return {"available": False, "reason": "recipient must contain 1 to 40 printable characters"}
    if not re.fullmatch(r"4[1-9A-HJ-NP-Za-km-z]{94}", data["project_address"]):
        return {"available": False, "reason": "project_address must be a primary Monero address"}
    if data["kind"] not in ("onion", "clearnet"):
        return {"available": False, "reason": "kind must be onion or clearnet"}
    match = re.fullmatch(r"([^:]+):([0-9]{1,5})", data["endpoint"])
    if match is None or not 1 <= int(match[2]) <= 65535:
        return {"available": False, "reason": "endpoint must be host:port with port 1 to 65535"}
    host = match[1]
    fingerprint = data.get("tls_fingerprint", "")
    if data["kind"] == "onion":
        if not re.fullmatch(r"[a-z2-7]{56}\.onion", host):
            return {"available": False, "reason": "endpoint must contain a v3 onion host"}
        if fingerprint:
            return {"available": False, "reason": "tls_fingerprint must be empty for onion"}
    else:
        labels = host.split(".")
        if (
            len(host) > 253
            or host.lower().endswith(".onion")
            or any(
                not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                for label in labels
            )
        ):
            return {"available": False, "reason": "endpoint must contain a valid clearnet host"}
        if not re.fullmatch(r"[0-9a-fA-F]{64}", fingerprint):
            return {"available": False, "reason": "tls_fingerprint must contain 64 hex characters"}
    return {"available": True, **{field: data.get(field, "") for field in _FIELDS}}
