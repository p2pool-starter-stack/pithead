"""Bounded proxy authentication probes that read credentials from stdin and never print them."""

import json
import socket
import sys


def login(password, host, require_upstream=False):
    request = {
        "id": 1,
        "method": "login",
        "params": {"login": "pithead-rotate-probe", "pass": password, "algo": ["rx/0"]},
    }
    try:
        with socket.create_connection((host, 3333), timeout=5) as connection:
            connection.sendall((json.dumps(request) + "\n").encode())
            with connection.makefile("rb") as stream:
                line = stream.readline(65537)
            if len(line) > 65536 or not line.endswith(b"\n"):
                return "failed"
            reply = json.loads(line)
            if not isinstance(reply, dict) or reply.get("id") != 1:
                return "failed"
            error = reply.get("error")
            if isinstance(error, dict) and error.get("message") == "Permission denied":
                return "refused"
            result = reply.get("result")
            if not error and isinstance(result, dict) and result.get("status") == "OK":
                job = result.get("job")
                if isinstance(job, dict) and all(
                    isinstance(job.get(key), str) and job[key]
                    for key in ("blob", "job_id", "target")
                ):
                    # Simple mode drops its upstream when the last authenticated client closes.
                    if not require_upstream or proxy_upstream_active():
                        return "accepted"
    except (OSError, ValueError):
        pass
    return "failed"


def proxy_upstream_active():
    from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient
    from mining_dashboard.config.config import PROXY_API_PORT, PROXY_AUTH_TOKEN, PROXY_HOST

    summary = XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN).get_summary()
    upstreams = summary.get("upstreams") if isinstance(summary, dict) else None
    active = upstreams.get("active") if isinstance(upstreams, dict) else None
    return type(active) is int and active > 0


def proxy_status(token):
    from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient, bounded_request
    from mining_dashboard.config.config import PROXY_API_PORT, PROXY_HOST

    client = XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, token)
    response = bounded_request(
        "GET", client.base_url + "/1/config", timeout=5, session=client.session
    )
    return response.status_code


if __name__ == "__main__":
    from mining_dashboard.config.config import PROXY_HOST

    secret = sys.stdin.read()
    verdict = (
        str(proxy_status(secret))
        if sys.argv[1] == "http"
        else login(secret, PROXY_HOST, require_upstream=sys.argv[1] == "stratum-route")
    )
    sys.exit(0 if verdict == sys.argv[2] else 1)
