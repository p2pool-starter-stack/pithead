import ipaddress
import socket

from mining_dashboard.config import config
from mining_dashboard.helper.utils import detect_host_ipv4, is_ip_address

HERE = "mining_here"
BACKUP = "on_backup"
NOT_CONNECTED = "not_connected"
UNKNOWN = "unknown"
ELSEWHERE = (BACKUP, NOT_CONNECTED)

_UNCONFIGURED_HOST = "Unknown Host"
_LOOPBACK = ("127.0.0.1", "::1", "localhost")


def _strip_host(host):
    return str(host).strip().strip("[]").lower()


def local_stratum_hosts():
    name = socket.gethostname()
    hosts = {config.HOST_IP, detect_host_ipv4(), name, f"{name}.local", *_LOOPBACK}
    if config.STRATUM_BIND != "0.0.0.0":
        hosts.add(config.STRATUM_BIND)
    return {_strip_host(h) for h in hosts if h and h != _UNCONFIGURED_HOST}


def _split_pool(pool):
    host, sep, port = pool.rpartition(":")
    if not sep or not (port.isascii() and port.isdigit()):
        return None
    return _strip_host(host), int(port)


def _knows_own_address(local_hosts):
    return any(is_ip_address(h) and not ipaddress.ip_address(h).is_loopback for h in local_hosts)


def _is_number(value):
    return isinstance(value, int | float) and not isinstance(value, bool)


def mining_verdict(payload, local_hosts, stratum_port):
    unknown = {"state": UNKNOWN, "pool": None}
    if not isinstance(payload, dict) or not payload.get("api_ok"):
        return unknown
    conn = payload.get("connection")
    if not isinstance(conn, dict):
        return unknown
    uptime, pool = conn.get("uptime"), conn.get("pool")
    if not _is_number(uptime):
        return unknown
    if uptime <= 0:
        return {"state": NOT_CONNECTED, "pool": None}
    if not isinstance(pool, str) or not pool.strip():
        return unknown
    pool = pool.strip()
    parsed = _split_pool(pool)
    if parsed is None:
        return {"state": UNKNOWN, "pool": pool}
    host, port = parsed
    if host in local_hosts:
        return {"state": HERE if port == stratum_port else BACKUP, "pool": pool}
    foreign = is_ip_address(host) and _knows_own_address(local_hosts)
    return {"state": BACKUP if foreign else UNKNOWN, "pool": pool}


def mines_elsewhere(worker):
    return (worker.get("mining") or {}).get("state") in ELSEWHERE
