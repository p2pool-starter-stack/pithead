"""Protocol-level remote-node checks for the first-boot wizard."""

import asyncio
import ipaddress
import socket
import time
from collections.abc import Awaitable, Callable
from contextlib import suppress

import grpc
import requests
from google.protobuf import empty_pb2
from requests.auth import HTTPDigestAuth

from mining_dashboard.client.tari.generated import base_node_pb2_grpc
from mining_dashboard.helper.http import bounded_get

_TIMEOUT = 5
_DIRECT_NETWORKS = tuple(
    ipaddress.ip_network(cidr)
    for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10")
)
_ZMTP_GREETING = b"\xff" + (b"\x00" * 8) + b"\x7f\x03\x01NULL" + (b"\x00" * 48)
_ZMTP_READY = b"\x04\x19\x05READY\x0bSocket-Type\x00\x00\x00\x03SUB"


def saved_probe(read_json: Callable[[str], dict]) -> dict | None:
    """Return only a complete verdict from the private wizard spool."""
    report = read_json("node-probe.json")
    return report if isinstance(report.get("ok"), bool) else None


def first_failure(report: dict) -> str:
    return next(
        (row["detail"] for row in report["probes"] if not row["ok"]),
        "A configured remote node could not be verified.",
    )


def _mode(cfg: dict, name: str, default: str = "local") -> str:
    section = cfg.get(name)
    return str(section.get("mode", default)) if isinstance(section, dict) else default


def _port(value, default: int) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        port = int(value)
    except (TypeError, ValueError):
        return None
    return port if 1 <= port <= 65535 else None


def _endpoint(cfg: dict, name: str, port_name: str, default_port: int) -> tuple[str, int | None]:
    section = cfg.get(name)
    remote = section.get("remote") if isinstance(section, dict) else None
    if not isinstance(remote, dict):
        return "", None
    return str(remote.get("host", "")).strip(), _port(
        remote.get(port_name, default_port), default_port
    )


def _firewall_enabled(cfg: dict) -> bool:
    network = cfg.get("network")
    value = network.get("tor_egress_firewall", True) if isinstance(network, dict) else True
    return value is not False


async def _resolved_address(host: str, port: int, firewall: bool) -> str | tuple[str, str]:
    """Resolve once, returning an allowed address or a refusal reason."""
    if not host or not all(c.isalnum() or c in ".:_-" for c in host) or len(host) > 253:
        return "address", "The node address is not a valid hostname or IP literal."
    try:
        infos = await asyncio.wait_for(
            asyncio.get_running_loop().getaddrinfo(host, port, type=socket.SOCK_STREAM),
            _TIMEOUT,
        )
    except TimeoutError:
        return "dns", "The node name did not resolve within the time allowed."
    except socket.gaierror:
        return "dns", "The node name did not resolve to an address."
    addresses = {ipaddress.ip_address(info[4][0].split("%", 1)[0]) for info in infos}
    if not addresses:
        return "dns", "The node name did not resolve to an address."
    if any(
        ip.is_loopback or ip.is_unspecified or ip.is_link_local or ip.is_multicast or ip.is_reserved
        for ip in addresses
    ):
        return (
            "address",
            "P2Pool runs in a container, so a loopback or host-only address points at the "
            "container instead of this machine. Use the node machine's LAN or VPN address.",
        )
    if firewall:
        # The firewall is an IPv4 allowlist and only the pinned address ever reaches the config,
        # so a dual-stack name's AAAA answer beside a usable private A record is not a refusal:
        # refusing it sent operators back to typing the literal IP (#2351).
        v4 = [ip for ip in addresses if isinstance(ip, ipaddress.IPv4Address)]
        allowed = sorted(ip for ip in v4 if any(ip in network for network in _DIRECT_NETWORKS))
        if not allowed or len(allowed) != len(v4):
            return (
                "address",
                "The Tor egress firewall lets mining containers dial remote nodes only on private "
                "LAN or VPN IPv4 ranges. Use that node's private address.",
            )
        return str(allowed[0])
    return str(sorted(addresses, key=lambda address: (address.version, int(address)))[0])


def _host_for_url(host: str) -> str:
    return f"[{host}]" if ":" in host and not host.startswith("[") else host


def _monero_rpc(cfg: dict, host: str, port: int) -> tuple[bool, str, str]:
    monero = cfg.get("monero") if isinstance(cfg.get("monero"), dict) else {}
    username = str(monero.get("node_username", ""))
    password = str(monero.get("node_password", ""))
    auth = HTTPDigestAuth(username, password) if username else None
    session = requests.Session()
    session.trust_env = False
    try:
        response = bounded_get(
            f"http://{_host_for_url(host)}:{port}/get_info",
            auth=auth,
            timeout=_TIMEOUT,
            allow_redirects=False,
            session=session,
        )
    except requests.Timeout:
        return False, "timeout", "The Monero RPC check timed out."
    except requests.ConnectionError:
        return False, "refused", "No connection was made to the Monero RPC endpoint."
    except requests.RequestException:
        return False, "unusable", "The Monero RPC check did not complete."
    finally:
        session.close()
    if response.status_code in (401, 403):
        return False, "auth", "The Monero node rejected the configured RPC login."
    if response.status_code != 200:
        return (
            False,
            "protocol",
            f"The endpoint returned HTTP {response.status_code}, not monerod get_info.",
        )
    try:
        body = response.json()
    except ValueError:
        return False, "protocol", "The endpoint did not return a JSON monerod get_info response."
    valid_ints = (
        all(
            isinstance(body.get(name), int)
            and not isinstance(body.get(name), bool)
            and body[name] >= 0
            for name in ("height", "target_height")
        )
        if isinstance(body, dict)
        else False
    )
    if (
        not isinstance(body, dict)
        or body.get("status") != "OK"
        or body.get("nettype") not in ("mainnet", "testnet", "stagenet")
        or not valid_ints
    ):
        return False, "protocol", "The endpoint did not return a usable monerod get_info response."
    return True, "ok", "The node answered monerod get_info with the configured RPC login."


async def _monero_zmq(host: str, port: int) -> tuple[bool, str, str]:
    writer = None
    try:
        async with asyncio.timeout(_TIMEOUT):
            reader, writer = await asyncio.open_connection(host, port)
            writer.write(_ZMTP_GREETING)
            await writer.drain()
            greeting = await reader.readexactly(64)
            if (
                greeting[0] != 0xFF
                or greeting[9] != 0x7F
                or greeting[10] < 3
                or greeting[12:32].rstrip(b"\x00") != b"NULL"
                or greeting[32] != 0
            ):
                return (
                    False,
                    "protocol",
                    "The endpoint answered, but sent an invalid ZMTP greeting.",
                )
            writer.write(_ZMTP_READY)
            await writer.drain()
            header = await reader.readexactly(2)
            if header[0] & 0x06 != 0x04 or header[1] > 64:
                return False, "protocol", "The endpoint did not complete the ZMTP READY exchange."
            command = await reader.readexactly(header[1])
    except TimeoutError:
        return False, "timeout", "The Monero ZMQ handshake timed out."
    except ConnectionRefusedError:
        return False, "refused", "No connection was made to the Monero ZMQ endpoint."
    except asyncio.IncompleteReadError:
        return False, "protocol", "The endpoint closed before the ZMTP handshake completed."
    except OSError:
        return False, "unusable", "The endpoint did not complete a ZMQ handshake."
    finally:
        if writer is not None:
            writer.close()
            with suppress(OSError):
                await writer.wait_closed()
    if not command.startswith(b"\x05READY") or _ready_socket_type(command) not in (b"PUB", b"XPUB"):
        return False, "protocol", "The endpoint did not complete the ZMTP READY exchange."
    return True, "ok", "The endpoint completed a live ZMTP greeting and READY exchange."


def _ready_socket_type(command: bytes) -> bytes | None:
    """Read the peer's Socket-Type metadata from a bounded ZMTP READY command."""
    offset = 6
    while offset < len(command):
        name_size = command[offset]
        offset += 1
        if offset + name_size + 4 > len(command):
            return None
        name = command[offset : offset + name_size]
        offset += name_size
        value_size = int.from_bytes(command[offset : offset + 4], "big")
        offset += 4
        if offset + value_size > len(command):
            return None
        value = command[offset : offset + value_size]
        offset += value_size
        if name == b"Socket-Type":
            return value
    return None


async def _tari_grpc(host: str, port: int) -> tuple[bool, str, str]:
    target = f"[{host}]:{port}" if ":" in host and not host.startswith("[") else f"{host}:{port}"
    channel = grpc.aio.insecure_channel(target)
    try:
        stub = base_node_pb2_grpc.BaseNodeStub(channel)
        await stub.GetTipInfo(empty_pb2.Empty(), timeout=_TIMEOUT)
    except grpc.aio.AioRpcError as exc:
        if exc.code() == grpc.StatusCode.DEADLINE_EXCEEDED:
            return False, "timeout", "The Tari gRPC check timed out."
        if exc.code() in (grpc.StatusCode.UNAUTHENTICATED, grpc.StatusCode.PERMISSION_DENIED):
            return False, "auth", "The Tari node rejected the gRPC request."
        return False, "unusable", "The endpoint did not complete Tari's GetTipInfo gRPC call."
    finally:
        await channel.close()
    return True, "ok", "The node answered Tari's GetTipInfo gRPC call."


async def _probe(
    target: str,
    host: str,
    port: int | None,
    checked: str,
    resolved: str | tuple[str, str],
    call: Callable[[str], Awaitable[tuple[bool, str, str]]],
) -> dict:
    started = time.monotonic()
    if port is None:
        ok, reason, detail = False, "address", "The node port must be an integer from 1 to 65535."
        shown_port = 0
    else:
        shown_port = port
        if isinstance(resolved, tuple):
            ok, reason, detail = False, *resolved
        else:
            ok, reason, detail = await call(resolved)
    return {
        "target": target,
        "host": host,
        "resolved_host": resolved if isinstance(resolved, str) else "",
        "port": shown_port,
        "ok": ok,
        "checked": checked,
        "reason": reason,
        "detail": detail,
        "elapsed_ms": max(0, int((time.monotonic() - started) * 1000)),
    }


async def probe_remote_nodes(cfg: dict) -> dict:
    """Check every endpoint the candidate's real p2pool consumer will use."""
    checks = []
    firewall = _firewall_enabled(cfg)
    if _mode(cfg, "monero") == "remote":
        host, rpc = _endpoint(cfg, "monero", "rpc_port", 18081)
        _, zmq = _endpoint(cfg, "monero", "zmq_port", 18083)
        resolved = await _resolved_address(host, rpc or zmq or 0, firewall)
        checks.extend(
            (
                _probe(
                    "monero",
                    host,
                    rpc,
                    "rpc",
                    resolved,
                    lambda address: asyncio.to_thread(_monero_rpc, cfg, address, rpc),
                ),
                _probe(
                    "monero",
                    host,
                    zmq,
                    "zmq",
                    resolved,
                    lambda address: _monero_zmq(address, zmq),
                ),
            )
        )
    if _mode(cfg, "tari") == "remote":
        host, port = _endpoint(cfg, "tari", "grpc_port", 18142)
        resolved = await _resolved_address(host, port or 0, firewall)
        checks.append(
            _probe("tari", host, port, "grpc", resolved, lambda address: _tari_grpc(address, port))
        )
    rows = await asyncio.gather(*checks)
    ok = all(row["ok"] is True for row in rows)
    if ok:
        for target in ("monero", "tari"):
            row = next((item for item in rows if item["target"] == target), None)
            if row:
                cfg[target]["remote"]["host"] = row["resolved_host"]
    return {
        "ok": ok,
        "configured": len(checks),
        "probed": len(rows),
        "probes": rows,
    }
