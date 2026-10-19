"""Exercise the running dashboard's command bot through the queued Telegram API."""

import json
import time
from urllib.parse import parse_qs, urlsplit

import requests

SINK = "http://fake-sink:9000"
STATE = "http://127.0.0.1:8000/api/state"


def request(url, payload=None):
    response = requests.request("GET" if payload is None else "POST", url, json=payload, timeout=5)
    response.raise_for_status()
    return response.json()


def require(condition, detail="command wire assertion failed"):
    if not condition:
        raise AssertionError(detail)


def poll(check, label):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.2)
    raise AssertionError(label)


def records():
    return request(SINK + "/control")["requests"]


def polls(rows):
    return [parse_qs(urlsplit(r["path"]).query) for r in rows if r["method"] == "GET"]


def replies(rows):
    return [
        json.loads(r["body"]) for r in rows if urlsplit(r["path"]).path.endswith("/sendMessage")
    ]


def update(update_id, chat):
    return {"update_id": update_id, "message": {"chat": {"id": chat}, "text": "/status"}}


def acknowledged(offset, count=3):
    rows = records()
    if sum(p.get("offset") == [str(offset)] for p in polls(rows)) >= count:
        return rows
    return None


poll(
    lambda: any(int(p.get("timeout", [0])[0]) > 0 for p in polls(records())),
    "bot never completed startup priming",
)
poll(
    lambda: all(s["state"] == "done" for s in request(STATE)["sync"].values()),
    "dashboard nodes never reached synced state",
)
request(SINK + "/control", {"reset": True, "updates": [update(201, "foreign-chat")]})
rows = poll(lambda: acknowledged(202), "foreign update was not acknowledged")
require(replies(rows) == [], "foreign chat received a reply")

request(SINK + "/control", {"updates": [update(202, "itest-chat")]})
rows = poll(lambda: acknowledged(203), "allowed update was not acknowledged")
sent = replies(rows)
require(len(sent) == 1, "expected exactly one reply to the allowed command")
require(sent[0]["chat_id"] == "itest-chat", "reply sent to an unconfigured chat")
state = request(STATE)
require(state["network"]["height"] == 3_000_000, "seeded P2Pool height is missing from API state")
require("Pithead status" in sent[0]["text"])
require(f"Workers: {state['proxy_workers']}/{len(state['workers'])} online" in sent[0]["text"])
require(f"Hashrate: {state['hashrate']['total']} (10m avg)" in sent[0]["text"])
require(f"PPLNS shares: {state['shares_window']['count']} in window" in sent[0]["text"])
require("Monero node: 🟢 synced" in sent[0]["text"])

# Retain the same update id so a regressed offset replays the command.
prior_polls = sum(p.get("offset") == ["203"] for p in polls(rows))
request(SINK + "/control", {"updates": [update(202, "itest-chat")]})
rows = poll(lambda: acknowledged(203, prior_polls + 3), "bot did not keep polling past replay")
require(len(replies(rows)) == 1, "acknowledged command was replayed")
print(
    "  ✓ Telegram /status matches API state, ignores foreign chat, advances offset and never replays"
)
