import json
import sys
import time
import urllib.request

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


config = request("config")
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
start = request("state")
preview = settled("preview", {"config": config}, None)
if preview.get("status") != "rejected":
    raise AssertionError("occupied stratum port preview was not rejected")
if "already in use" not in preview.get("log", ""):
    raise AssertionError("refusal did not identify occupied port")
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    state = request("state")
    if state.get("proxy_workers", 0) > 0 and state.get("stratum", {}).get(
        "total_hashes", 0
    ) > start.get("stratum", {}).get("total_hashes", 0):
        print("occupied stratum preview refused; mining continues")
        break
    time.sleep(3)
else:
    raise AssertionError("mining did not continue after occupied-port refusal")
