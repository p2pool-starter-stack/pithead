"""Typed projections for subnet diagnostics; no raw strings escape these parsers."""

import hashlib
import json
import re
from datetime import datetime


def numbers(obj, fields):
    return {
        key: obj[key]
        for key in fields.split()
        if type(obj.get(key)) in (int, float) and 0 <= obj[key] <= 2**64
    }


def monero_info(raw):
    obj = json.loads(raw)
    if obj.get("status") != "OK":
        raise ValueError
    out = numbers(obj, "height target_height")
    if len(out) != 2:
        raise ValueError
    if type(obj.get("synchronized")) is bool:
        out["synchronized"] = obj["synchronized"]
    out["rpc_visibility"] = "unrestricted" if obj.get("restricted") is False else "unverified"
    if obj.get("restricted") is False:
        out.update(
            numbers(
                obj,
                "outgoing_connections_count incoming_connections_count white_peerlist_size grey_peerlist_size",
            )
        )
    else:
        out["peer_counts"] = "unavailable-restricted-or-missing-flag"
    if (
        obj.get("restricted") is False
        and len(
            numbers(
                obj,
                "outgoing_connections_count incoming_connections_count white_peerlist_size grey_peerlist_size",
            )
        )
        != 4
    ):
        raise ValueError
    return out


def monero_transfer(raw, method):
    obj = json.loads(raw)["result"]
    if obj.get("status") != "OK" or obj.get("restricted") is True:
        raise ValueError
    fields = "height target_height next_needed_pruning_seed"
    out = numbers(obj, fields)
    rows = obj["connections"] if method == "get_connections" else obj["peers"]
    if not isinstance(rows, list):
        raise ValueError
    out["peers"] = []
    if any(
        not isinstance(row, dict)
        or (method == "sync_info" and not isinstance(row.get("info"), dict))
        for row in rows
    ):
        raise ValueError
    for row in rows[:64]:
        row = row["info"] if method == "sync_info" else row
        if len(numbers(row, "height")) != 1:
            raise ValueError
        peer = numbers(
            row,
            "height recv_count send_count recv_idle_time send_idle_time current_download current_upload avg_download avg_upload live_time",
        )
        if type(row.get("incoming")) is bool:
            peer["incoming"] = row["incoming"]
        # Never preserve a connection id, peer address, host, or arbitrary state string.
        out["peers"].append(peer)
    out["peer_count"] = len(rows)
    out["peers_clipped"] = len(rows) > 64
    spans = obj["spans"] if method == "sync_info" else []
    if not isinstance(spans, list) or any(not isinstance(row, dict) for row in spans):
        raise ValueError
    out["spans"] = [
        numbers(row, "start_block_height nblocks rate speed size") for row in spans[:64]
    ]
    out["spans_clipped"] = len(spans) > 64
    return out


def tor_control(raw, field):
    """Validate authentication and GETINFO framing before interpreting empty populations."""
    lines = raw.splitlines()
    if not lines or lines.pop(0) != "250 OK" or lines[-2:] != ["250 OK", "250 closing connection"]:
        raise ValueError
    lines = lines[:-2]
    if lines == [f"250-{field}="]:
        rows = []
    elif len(lines) >= 2 and lines[0] == f"250+{field}=" and lines[-1] == ".":
        rows = lines[1:-1]
    else:
        raise ValueError
    allowed = (
        {"LAUNCHED", "BUILT", "GUARD_WAIT", "EXTENDED", "FAILED", "CLOSED"}
        if field == "circuit-status"
        else {
            "NEW",
            "NEWRESOLVE",
            "REMAP",
            "SENTCONNECT",
            "SENTRESOLVE",
            "SUCCEEDED",
            "FAILED",
            "CLOSED",
            "DETACHED",
            "CONTROLLER_WAIT",
            "XOFF_SENT",
            "XOFF_RECV",
            "XON_SENT",
            "XON_RECV",
        }
    )
    counts = {}
    for row in rows:
        parts = row.split()
        if len(parts) < 2 or not parts[0].isdigit():
            raise ValueError
        state = parts[1] if parts[1] in allowed else "other"
        counts[state] = counts.get(state, 0) + 1
    return {"total": len(rows), "states": counts}


def tor_history(raw):
    out = {"bin_count": 0, "bin_samples": 0}
    for line in raw.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] in {"TotalBuildTimes", "CircuitBuildAbandonedCount"}:
            if len(parts) != 2 or not parts[1].isdigit() or parts[0] in out:
                raise ValueError
            out[parts[0]] = int(parts[1])
        elif parts[0] == "CircuitBuildTimeBin":
            if len(parts) != 3 or not all(p.isdigit() for p in parts[1:]):
                raise ValueError
            out["bin_count"] += 1
            out["bin_samples"] += int(parts[2])
    if not {"TotalBuildTimes", "CircuitBuildAbandonedCount"} <= out.keys():
        raise ValueError
    return out


def container(raw, expected):
    obj = json.loads(raw)[0]
    state = obj["State"]
    cid = obj["Id"]
    if not re.fullmatch(r"[0-9a-f]{64}", cid):
        raise ValueError
    out = {"identity": hashlib.sha256(cid.encode()).hexdigest()[:16]}
    for name, value, allowed in (
        (
            "state",
            state.get("Status"),
            {"running", "exited", "restarting", "paused", "created", "dead", "removing"},
        ),
        ("health", state.get("Health", {}).get("Status"), {"healthy", "unhealthy", "starting"}),
    ):
        out[name] = value if value in allowed else "unknown"
    stamp = state.get("StartedAt", "")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z", stamp):
        datetime.fromisoformat(stamp)
        out["started_at"] = stamp
    out.update(numbers(state, "ExitCode"))
    out.update(numbers(obj, "RestartCount"))
    if type(state.get("OOMKilled")) is bool:
        out["oom_killed"] = state["OOMKilled"]
    networks = obj["NetworkSettings"]["Networks"]
    out["mining_network_present"] = "mining_net" in networks
    if expected:
        out["address_matches_render"] = networks.get("mining_net", {}).get("IPAddress") == expected
    return out


def firewall(raw, backend):
    if backend == "iptables":
        rows = []
        for line in raw.splitlines():
            match = re.match(r"\[(\d+):(\d+)\] -A DOCKER-USER (.*)", line)
            if match and "pithead-tor-egress" in match[3]:
                target = re.search(r" -j (ACCEPT|DROP|REJECT|RETURN)(?: |$)", " " + match[3])
                rows.append(
                    {
                        "packets": int(match[1]),
                        "bytes": int(match[2]),
                        "action": target[1] if target else "other",
                    }
                )
        return {"tagged_rules": rows, "count": len(rows)}
    rows = []
    for item in json.loads(raw)["nftables"]:
        if "rule" in item:
            row = {"actions": []}
            for expr in item["rule"]["expr"]:
                if "counter" in expr and isinstance(expr["counter"], dict):
                    row.update(numbers(expr["counter"], "packets bytes"))
                row["actions"].extend(
                    key for key in ("accept", "drop", "reject", "return") if key in expr
                )
            rows.append(row)
    return {"rules": rows, "count": len(rows)}
