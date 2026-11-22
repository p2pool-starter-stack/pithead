# ruff: noqa: E402, I001, S101
import sys

LABELS = ("health", "notify")
TRACE_URL = "https://1.1.1.1/cdn-cgi/trace"


def parse_ip(body):
    for line in body.splitlines():
        if line.startswith("ip="):
            return line[3:].strip() or None
    return None


def collided(ips):
    return len(set(ips.values())) < len(ips)


def ip_class(ip):
    return "v6" if ":" in ip else "v4"


if sys.argv[1:] == ["--self-test"]:
    assert parse_ip("fl=1\nip=203.0.113.7\nts=1\n") == "203.0.113.7"
    assert parse_ip("fl=1\nts=1\n") is None
    assert parse_ip("ip=\n") is None
    assert collided({"health": "a", "notify": "a"})
    assert not collided({"health": "a", "notify": "b"})
    assert ip_class("2001:db8::1") == "v6" and ip_class("203.0.113.7") == "v4"
    raise SystemExit(0)

from mining_dashboard.config.config import TOR_SOCKS_PROXY
from mining_dashboard.helper.http import bounded_get, proxy_map, purpose_proxy


def fetch_ip(label):
    try:
        resp = bounded_get(
            TRACE_URL, timeout=30, proxies=proxy_map(purpose_proxy(TOR_SOCKS_PROXY, label))
        )
        return parse_ip(resp.text) if resp.status_code == 200 else None
    except Exception as exc:
        print(f"{label}: fetch failed ({type(exc).__name__})", file=sys.stderr)
        return None


def run(attempt):
    suffix = "" if attempt == 1 else f"-{attempt}"
    ips = {label: fetch_ip(f"{label}{suffix}") for label in LABELS}
    for label, ip in ips.items():
        print(f"{label}{suffix}: {ip_class(ip) if ip else 'no answer'}")
    return ips


ips = run(1)
if all(ips.values()) and collided(ips):
    print("exit collision; retrying once with fresh purpose identities")
    ips = run(2)
ok = all(ips.values()) and not collided(ips)
print("purposes exit distinct circuits" if ok else "purposes did not get distinct exits")
raise SystemExit(0 if ok else 1)
