import json
import re
import sys
from datetime import datetime

PREFIX = "pithead-tor-lifecycle "
FIELDS = {"timestamp", "caller", "operation", "container", "action", "result"}


def project(line):
    if PREFIX not in line:
        return None
    try:
        row = json.loads(line.split(PREFIX, 1)[1])
        if not isinstance(row, dict) or set(row) != FIELDS:
            return None
        if any(not isinstance(value, str) for value in row.values()):
            return None
        if row["caller"] not in {"onion-rotation", "tor-heal"}:
            return None
        if not re.fullmatch(
            r"(?:rotate-\d{1,12}-\d{1,12}|[a-f0-9]{32}|unavailable)", row["operation"]
        ):
            return None
        if not re.fullmatch(r"(?:[a-f0-9]{64}|unavailable)", row["container"]):
            return None
        if row["action"] not in {"stop", "start", "up", "recover"}:
            return None
        if row["result"] not in {"requested", "confirmed", "unconfirmed"} and not re.fullmatch(
            r"\d{1,3}", row["result"]
        ):
            return None
        stamp = row["timestamp"]
        if (
            len(stamp) > 35
            or datetime.fromisoformat(stamp.replace("Z", "+00:00")).utcoffset().total_seconds() != 0
        ):
            return None
        return row
    except (ValueError, TypeError, AttributeError):
        return None


def collect():
    count = 0
    oversized = False
    while chunk := sys.stdin.buffer.readline(1025):
        complete = chunk.endswith(b"\n")
        if not oversized and len(chunk) <= 1024:
            row = project(chunk.decode("utf-8", "replace"))
            if row is not None and complete and count < 128:
                print(json.dumps(row, separators=(",", ":")))
                count += 1
        oversized = not complete


def verify(paths):
    rows = []
    for path in paths:
        with open(path, "rb") as source:
            data = source.read(131073)
        require(len(data) <= 131072, "receipt artifact exceeds its bound")
        for line in data.decode().splitlines():
            row = project(PREFIX + line)
            require(row is not None, "receipt artifact contains an invalid record")
            require(row["operation"] != "unavailable", "receipt has no operation identity")
            rows.append(row)
    for caller, actions, result in (
        ("onion-rotation", ("stop", "up"), "0"),
        ("tor-heal", ("stop", "start"), "confirmed"),
    ):
        for action in actions:
            matches = [r for r in rows if r["caller"] == caller and r["action"] == action]
            require(any(r["result"] == "requested" for r in matches), "missing requested action")
            require(
                any(r["result"] == result and r["container"] != "unavailable" for r in matches),
                "missing engine identity or result",
            )
    require(
        any(r["caller"] == "tor-heal" and r["result"] == "unconfirmed" for r in rows),
        "missing failed-call receipt",
    )


def require(condition, message):
    if not condition:
        raise ValueError(message)


if __name__ == "__main__":
    if sys.argv[1:] == ["collect"]:
        collect()
    else:
        verify(sys.argv[1:])
