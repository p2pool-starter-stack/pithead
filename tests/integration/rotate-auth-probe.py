import contextlib
import hashlib
import json
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, build_opener


def login(
    password, host, require_upstream=False, *, port=3333, worker="pithead-rotate-probe", pin=None
):
    request = {
        "id": 1,
        "method": "login",
        "params": {"login": worker, "rigid": worker, "algo": ["rx/0"]},
    }
    if password is not None:
        request["params"]["pass"] = password
    try:
        with contextlib.ExitStack() as stack:
            transport = stack.enter_context(socket.create_connection((host, port), timeout=5))
            connection = transport
            if pin is not None:
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
                connection = stack.enter_context(
                    context.wrap_socket(transport, server_hostname=host)
                )
                if hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest() != pin:
                    return "pin-refused"
            connection.sendall((json.dumps(request) + "\n").encode())
            with connection.makefile("rb") as stream:
                line = stream.readline(65537)
            if len(line) > 65536 or not line.endswith(b"\n"):
                return "failed"
            reply = json.loads(line)
            if not isinstance(reply, dict) or reply.get("id") != 1:
                return "failed"
            error = reply.get("error")
            if (
                isinstance(error, dict)
                and error.get("message") == "Permission denied"
                and not reply.get("result")
            ):
                return "refused"
            result = reply.get("result")
            if not error and isinstance(result, dict) and result.get("status") == "OK":
                job = result.get("job")
                if isinstance(job, dict) and all(
                    isinstance(job.get(key), str) and job[key]
                    for key in ("blob", "job_id", "target")
                ):
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


def worker_sample(name):
    code = (
        "import json; from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient; "
        "from mining_dashboard.config.config import PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN; "
        "print(json.dumps(XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN).get_workers()))"
    )
    result = subprocess.run(  # noqa: S603
        ["docker", "exec", "dashboard", "python3", "-c", code],  # noqa: S607
        capture_output=True,
        timeout=15,
        check=True,
    )
    if len(result.stdout) > 1048576:
        raise ValueError("worker response exceeds bound")
    return worker_counter(json.loads(result.stdout), name)


def worker_counter(body, name):
    if not isinstance(body, dict) or not isinstance(body.get("workers"), list):
        raise ValueError("worker list missing")
    matches = [row for row in body["workers"] if isinstance(row, list) and row and row[0] == name]
    if len(matches) != 1 or len(matches[0]) < 4:
        raise ValueError("unique retained worker missing")
    connections, accepted = matches[0][2:4]
    if any(type(value) is not int or value < 0 for value in (connections, accepted)):
        raise ValueError("worker counters are not nonnegative integers")
    return connections, accepted


def wait_counter(name, predicate, seconds=30):
    deadline = time.monotonic() + seconds
    while True:
        if predicate(worker_sample(name)):
            return
        if time.monotonic() >= deadline:
            raise ValueError("worker counter deadline exceeded")
        time.sleep(2)


def raw_control(password, port, name, pin, expected, seconds):
    deadline = time.monotonic() + seconds
    while True:
        if worker_sample(name) != (0, 0):
            raise ValueError("negative worker became active or accepted a share")
        verdict = login(password, "127.0.0.1", port=port, worker=name, pin=pin)
        if verdict != expected or worker_sample(name) != (0, 0):
            raise ValueError("negative login did not preserve refusal and zero counters")
        if time.monotonic() >= deadline:
            return
        time.sleep(2)


def xmrig_control(binary, password, port, name, pin, expected, seconds):
    pool = {"url": f"127.0.0.1:{port}", "user": name + "+100", "rig-id": name, "coin": "monero"}
    if password is not None:
        pool["pass"] = password
    if pin is not None:
        pool.update({"tls": True, "tls-fingerprint": pin})
    config = {
        "autosave": False,
        "colors": False,
        "donate-level": 0,
        "randomx": {"mode": "light"},
        "cpu": {"enabled": True, "huge-pages": False, "rx": [0]},
        "opencl": False,
        "cuda": False,
        "pools": [pool],
        "retries": 100,
        "retry-pause": 2,
    }
    baseline = worker_sample(name)[1]
    with tempfile.TemporaryDirectory(prefix="pithead-stratum-") as directory:
        config_file = Path(directory) / "config.json"
        config_file.write_text(json.dumps(config))
        config_file.chmod(0o600)
        log_file = Path(directory) / "miner.log"
        with log_file.open("w") as log:
            process = subprocess.Popen(  # noqa: S603
                [binary, "--config", str(config_file)], stdout=log, stderr=log
            )
            try:
                deadline = time.monotonic() + seconds
                while True:
                    if process.poll() is not None:
                        raise ValueError("test miner exited before its assertion")
                    with log_file.open() as reader:
                        text = reader.read(1048577)
                    if len(text) > 1048576:
                        raise ValueError("test miner log exceeds bound")
                    sample = worker_sample(name)
                    has_job = "new job from" in text
                    if expected == "accepted":
                        if has_job and sample[1] > baseline:
                            return
                    else:
                        if has_job or sample != (0, 0):
                            raise ValueError("negative miner received a job or became active")
                    if time.monotonic() >= deadline:
                        marker = (
                            'error: "Permission denied"'
                            if expected == "refused"
                            else "Failed to verify server certificate fingerprint"
                        )
                        if expected != "accepted" and marker in text:
                            return
                        raise ValueError("test miner never established the required verdict")
                    time.sleep(2)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def stratum_controls(binary=None):
    with build_opener(ProxyHandler({})).open(
        "http://127.0.0.1:8000/api/miner-connection", timeout=10
    ) as response:
        body = response.read(1048577)
    if len(body) > 1048576:
        raise ValueError("connection card exceeds bound")
    card = json.loads(body)
    if not isinstance(card, dict):
        raise ValueError("connection card is not an object")
    password, pin = card.get("password"), card.get("fingerprint")
    port = urlsplit(card.get("url", "")).port
    if (
        not isinstance(password, str)
        or not password
        or card.get("tls") is not True
        or not isinstance(pin, str)
        or len(pin) != 64
        or any(c not in "0123456789abcdef" for c in pin)
        or port is None
    ):
        raise ValueError("connection card lacks password, TLS identity or port")
    name = "pithead-auth-" + uuid.uuid4().hex
    print("stratum fixture: creating retained worker", flush=True)
    if login(password, "127.0.0.1", port=port, worker=name) != "accepted":
        raise ValueError("retained-worker fixture login did not receive a job")
    wait_counter(name, lambda sample: sample == (0, 0))
    print(
        "stratum fixture: authenticated without shares, disconnected; connections=0 accepted=0",
        flush=True,
    )
    wrong = password + "-incorrect"
    flipped = ("1" if pin[0] == "0" else "0") + pin[1:]
    for label, credential, fingerprint, expected in (
        ("wrong password", wrong, None, "refused"),
        ("missing password", None, None, "refused"),
        ("incorrect TLS pin", password, flipped, "pin-refused"),
    ):
        print(f"stratum control starting: {label}", flush=True)
        if binary:
            xmrig_control(binary, credential, port, name, fingerprint, expected, 120)
        else:
            raw_control(credential, port, name, fingerprint, expected, 120)
        wait_counter(name, lambda sample: sample == (0, 0))
        print(
            f"stratum control: {label}: explicit refusal, no job, connections=0 accepted=0 for 120s",
            flush=True,
        )
    if binary:
        raw_control(None, port, name, None, "refused", 120)
        print(
            "stratum control: omitted wire password refused with zero counters for 120s", flush=True
        )
    for label, fingerprint in (("correct TLS pin", pin), ("same-port cleartext", None)):
        print(f"stratum control starting: {label}", flush=True)
        if binary:
            baseline = worker_sample(name)[1]
            xmrig_control(binary, password, port, name, fingerprint, "accepted", 600)
            wait_counter(
                name, lambda sample, baseline=baseline: sample[0] == 0 and sample[1] > baseline
            )
        elif login(password, "127.0.0.1", port=port, worker=name, pin=fingerprint) != "accepted":
            raise ValueError("positive control did not receive a mining job")
        print(
            f"stratum control: {label}: "
            + ("accepted share" if binary else "authenticated mining job"),
            flush=True,
        )


if __name__ == "__main__":
    if sys.argv[1] == "controls":
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        try:
            stratum_controls(sys.argv[2] if len(sys.argv) == 3 else None)
        except (OSError, ValueError, subprocess.SubprocessError):
            print("stratum controls failed; no credentials or miner output published", flush=True)
            sys.exit(1)
    else:
        from mining_dashboard.config.config import PROXY_HOST

        secret = sys.stdin.read()
        verdict = (
            str(proxy_status(secret))
            if sys.argv[1] == "http"
            else login(secret, PROXY_HOST, require_upstream=sys.argv[1] == "stratum-route")
        )
        sys.exit(0 if verdict == sys.argv[2] else 1)
