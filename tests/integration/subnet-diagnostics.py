#!/usr/bin/env python3
"""Read-only first-timeout evidence; emit only typed fields, never raw probe data."""

import ipaddress
import json
import os
import selectors
import signal
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path

from subnet_diagnostic_summary import (
    container,
    firewall,
    monero_info,
    monero_transfer,
    tor_control,
    tor_history,
)

LIMIT = 131072
SERVICES = ("monerod", "tari", "tor", "dashboard", "p2pool", "xmrig-proxy")


def run(argv, seconds=5, limit=LIMIT):
    """A hung or noisy probe must not stall the timeout path or leak raw stderr."""
    started = time.monotonic()
    data = bytearray()
    try:
        with subprocess.Popen(  # noqa: S603 — callers use fixed local probe commands.
            argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True
        ) as process:
            with selectors.DefaultSelector() as poll:
                poll.register(process.stdout, selectors.EVENT_READ)
                try:
                    while poll.get_map():
                        left = seconds - (time.monotonic() - started)
                        if left <= 0:
                            raise TimeoutError
                        for key, _ in poll.select(min(left, 0.1)):
                            block = os.read(key.fd, 4096)
                            if not block:
                                poll.unregister(key.fileobj)
                            elif len(data) + len(block) > limit:
                                raise OverflowError
                            else:
                                data.extend(block)
                    rc = process.wait(timeout=max(0.001, seconds - (time.monotonic() - started)))
                    if rc:
                        return {"error": "command-failed", "exit_code": rc}, None
                except (
                    TimeoutError,
                    OverflowError,
                    subprocess.TimeoutExpired,
                    InterruptedError,
                ) as exc:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    if isinstance(exc, InterruptedError):
                        raise SystemExit(128 + signal.SIGTERM) from None
                    return {
                        "error": "output-limit" if isinstance(exc, OverflowError) else "timeout"
                    }, None
    except OSError:
        return {"error": "command-unavailable"}, None
    return {"exit_code": 0}, data.decode("utf-8", errors="replace")


def emit(probe, result):
    print(
        json.dumps({"probe": probe, "utc": datetime.now(UTC).isoformat(), **result}),
        flush=True,
    )


def sample(probe, argv, parse):
    result, raw = run(argv)
    if raw is not None:
        try:
            result["summary"] = parse(raw)
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, RecursionError):
            result["error"] = "invalid-or-unavailable-reading"
    emit(probe, result)
    return result.get("summary", {})


def rpc(method):
    # Credentials are read inside the container and sent to curl on stdin, never argv.
    request = (
        ""
        if method == "get_info"
        else f'-H \'Content-Type: application/json\' -d \'{{"jsonrpc":"2.0","id":"0","method":"{method}"}}\''
    )
    endpoint = "get_info" if method == "get_info" else "json_rpc"
    script = """set -eu
printf 'user = %s\\n' "$(printf '%s:%s' "${MONERO_NODE_USERNAME:-}" "${MONERO_NODE_PASSWORD:-}" | jq -Rs .)" |
curl -fsS --max-time 3 --max-filesize 131072 --digest --config - """
    return [
        "docker",
        "exec",
        "monerod",
        "sh",
        "-c",
        f"{script} {request} http://127.0.0.1:18085/{endpoint}",
    ]


def collect():
    try:
        env = dict(
            line.split("=", 1) for line in Path(".env").read_text().splitlines() if "=" in line
        )
        config = json.loads(Path("config.json").read_text())
        subnet = str(ipaddress.ip_network(env["NETWORK_SUBNET"]))
        prefix = str(ipaddress.IPv4Address(env["NETWORK_PREFIX"] + ".0"))[:-2]
        emit(
            "rendered-network",
            {
                "summary": {
                    "subnet_matches_config": subnet
                    == config.get("network", {}).get("subnet", "172.28.0.0/24"),
                    "prefix_matches_subnet": prefix + ".0/24" == subnet,
                    **{
                        key: env.get(key) if env.get(key) in {"true", "false"} else "unknown"
                        for key in (
                            "TOR_EGRESS_FIREWALL",
                            "MONERO_CLEARNET_SYNC",
                            "TARI_CLEARNET_SYNC",
                            "P2POOL_CLEARNET",
                        )
                    },
                }
            },
        )
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError):
        prefix, subnet = "", ""
        emit("rendered-network", {"error": "render-unavailable"})
    for service in SERVICES:
        suffix = {"tor": 25, "monerod": 26, "tari": 27, "p2pool": 28, "xmrig-proxy": 29}.get(
            service
        )
        sample(
            "container-" + service,
            ["docker", "inspect", service],
            lambda raw, suffix=suffix: container(
                raw, f"{prefix}.{suffix}" if prefix and suffix else ""
            ),
        )
    sample(
        "live-network",
        ["docker", "network", "inspect", "mining_net"],
        lambda raw: {
            "subnet_matches_render": bool(subnet)
            and [row["Subnet"] for row in json.loads(raw)[0]["IPAM"]["Config"]] == [subnet]
        },
    )
    for probe, argv, expected in (
        (
            "monero-proxy",
            [
                "docker",
                "exec",
                "monerod",
                "sh",
                "-c",
                "grep '^proxy=' /home/ubuntu/.bitmonero/bitmonero.conf",
            ],
            f"proxy={prefix}.25:9050",
        ),
        (
            "tor-control-bind",
            ["docker", "exec", "tor", "sh", "-c", "grep '^ControlPort ' /tmp/torrc"],
            f"ControlPort {prefix}.25:9051",
        ),
    ):
        sample(
            probe,
            argv,
            lambda raw, expected=expected: {
                "matches_render": bool(prefix) and expected in raw.splitlines()
            },
        )
    info = sample("monero-admin-info", rpc("get_info"), monero_info)
    for method in ("get_connections", "sync_info"):
        if info.get("rpc_visibility") == "unrestricted":
            sample(
                "monero-" + method,
                rpc(method),
                lambda raw, method=method: monero_transfer(raw, method),
            )
        else:
            emit("monero-" + method, {"error": "admin-rpc-unverified"})
    for field in ("circuit-status", "stream-status"):
        script = (
            """set -eu
cookie=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie | tr -d '\\n')
[ "${#cookie}" -eq 64 ] || exit 3
case "$cookie" in *[!0-9a-fA-F]*) exit 3 ;; esac
"""
            + f"printf 'AUTHENTICATE %s\\r\\nGETINFO {field}\\r\\nQUIT\\r\\n' \"$cookie\" | nc -w 3 127.0.0.1 9051"
        )
        sample(
            "tor-" + field,
            ["docker", "exec", "tor", "sh", "-c", script],
            lambda raw, field=field: tor_control(raw, field),
        )
    sample("tor-build-history", ["docker", "exec", "tor", "cat", "/var/lib/tor/state"], tor_history)
    sample(
        "firewall-enforcement",
        ["bash", "-c", "source ./pithead >/dev/null 2>&1; tor_egress_enforced"],
        lambda raw: {"enforced": True},
    )
    for backend, argv in (
        ("iptables", ["sudo", "-n", "iptables-save", "-c", "-t", "filter"]),
        ("nft", ["sudo", "-n", "nft", "-j", "list", "table", "inet", "pithead_egress"]),
    ):
        sample("firewall-" + backend, argv, lambda raw, backend=backend: firewall(raw, backend))

    emit("collection", {"complete": True})


def stop_collection(_signum, _frame):
    # Let the active reader kill its probe group before the outer timeout escalates.
    raise InterruptedError


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop_collection)
    collect()
