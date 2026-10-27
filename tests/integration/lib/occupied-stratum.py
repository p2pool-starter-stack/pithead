import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

port = int(sys.argv[1])


def request(route, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:8000/api/" + route,
        data=data,
        headers={
            "Content-Type": "application/json",
            "X-Auth-User": "itest",
            "X-Pithead-Control": "1",
        },
    )
    with urllib.request.urlopen(req, timeout=45) as response:  # noqa: S310
        return json.load(response)


def settled(route, body, exclude):
    result = request("control/" + route, body)
    request_id = result["id"]
    deadline = time.monotonic() + 90
    while result.get("status") in {"pending", exclude}:
        if time.monotonic() >= deadline:
            raise AssertionError("control request did not settle")
        time.sleep(2)
        result = request("control/result?id=" + request_id)
    return result


def diagnostic_counter(value):
    if type(value) is int:
        return value
    if isinstance(value, str) and len(value) <= 64:
        digits = value.replace(",", "")
        if digits.isascii() and digits.isdigit():
            return int(digits)
    return None


def stratum_sample():
    try:
        with Path("/app/stats/local/stratum").open("rb") as source:
            raw = source.read(65537)
        data = json.loads(raw) if len(raw) <= 65536 else None
        if not isinstance(data, dict):
            raise ValueError
    except (OSError, ValueError):
        return {"source_status": "unavailable"}
    return {
        "source_status": "read",
        "source_hashes": diagnostic_counter(data.get("total_hashes")),
        "source_shares": diagnostic_counter(data.get("total_shares")),
    }


def wait_mining(start, timeout, phase, allow_reset=False):
    initial = start.get("stratum", {}).get("total_hashes", 0)
    began = time.monotonic()
    deadline = began + timeout
    next_report = began
    state = start
    while time.monotonic() < deadline:
        state = request("state")
        hashes = state.get("stratum", {}).get("total_hashes", 0)
        workers = state.get("proxy_workers", 0)
        now = time.monotonic()
        if now >= next_report:
            summary = state.get("proxy_summary", {})
            print(
                "mining sample "
                + json.dumps(
                    {
                        **stratum_sample(),
                        "phase": phase,
                        "elapsed_seconds": int(now - began),
                        "workers": diagnostic_counter(workers),
                        "hashes": diagnostic_counter(hashes),
                        "stratum_shares": diagnostic_counter(
                            state.get("stratum", {}).get("total_shares")
                        ),
                        "proxy_accepted": diagnostic_counter(summary.get("accepted")),
                        "proxy_rejected": diagnostic_counter(summary.get("rejected")),
                        "proxy_invalid": diagnostic_counter(summary.get("invalid")),
                        "snapshot_changed": state.get("last_update") != start.get("last_update")
                        if "last_update" in state and "last_update" in start
                        else None,
                    }
                ),
                flush=True,
            )
            next_report = now + 15
        if allow_reset and hashes < initial:
            print(f"{phase}: counter reset {initial}->{hashes}", flush=True)
            initial = hashes
        if workers > 0 and hashes > initial:
            print(f"{phase}: workers={workers}, hashes={initial}->{hashes}", flush=True)
            return state
        time.sleep(3)
    raise AssertionError(
        f"mining did not progress {phase}: initial_hashes={initial}, "
        f"workers={state.get('proxy_workers', 0)}, "
        f"hashes={state.get('stratum', {}).get('total_hashes', 0)}"
    )


deadline = time.monotonic() + 90
while True:
    try:
        config = request("config")
        break
    except urllib.error.URLError as exc:
        if not isinstance(exc.reason, ConnectionRefusedError):
            raise
        if time.monotonic() >= deadline:
            raise AssertionError(
                "dashboard configuration unavailable before occupied-port preview"
            ) from exc
        time.sleep(2)
for dotted in config.get("_default_keys", []):
    parts = dotted.split(".")
    node = config
    for part in parts[:-1]:
        node = node.get(part, {})
    node.pop(parts[-1], None)
config = {key: value for key, value in config.items() if not key.startswith("_")}
if config.get("p2pool", {}).get("stratum_port", 3333) == port:
    raise AssertionError("occupied test port must differ from the current stratum port")
config.setdefault("p2pool", {}).update(stratum_port=port, stratum_bind="0.0.0.0")
start = wait_mining(request("state"), 180, "before occupied-port preview", allow_reset=True)
preview = settled("preview", {"config": config}, None)
if preview.get("status") != "rejected":
    raise AssertionError("occupied stratum port preview was not rejected")
if "already in use" not in preview.get("log", ""):
    raise AssertionError("refusal did not identify occupied port")
wait_mining(start, 90, "after occupied-port refusal")
print("occupied stratum preview refused; mining continues")
