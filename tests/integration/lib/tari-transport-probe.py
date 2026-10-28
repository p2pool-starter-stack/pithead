import datetime
import json
import re
import select
import shlex
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

TAG = "pithead-e2e-fault-tari-transport"
TIMEOUT = 240


def operation_name(args):
    if args[:2] == ("docker", "inspect"):
        return "inspect-" + (
            args[2] if args[2] in {"p2pool", "tari", "xmrig-proxy"} else "container"
        )
    if args[:2] == ("docker", "logs"):
        return "p2pool-log-read"
    if args[:3] == ("docker", "exec", "-i"):
        return "p2pool-console-write"
    if args[:3] == ("docker", "exec", "dashboard"):
        return "proxy-summary"
    if args[:3] == ("sudo", "-n", "nsenter") and args[6:7] == ("iptables",):
        return {"-S": "fault-rule-list", "-I": "fault-rule-insert", "-D": "fault-rule-remove"}.get(
            args[7], "fault-rule-operation"
        )
    return "probe-subprocess"


def failure_class(stderr):
    for field in ("miners", "now", "results", "accepted", "hashes_total"):
        if re.search(r"(?:^|\n)KeyError: ['\"]" + field + r"['\"](?:\n|$)", stderr):
            return "KeyError:" + field
    for name in (
        "KeyError",
        "ImportError",
        "ModuleNotFoundError",
        "SyntaxError",
        "PermissionError",
    ):
        if re.search(r"(?:^|\n)" + name + r":", stderr):
            return name
    for fragment, name in (
        ("permission denied", "permission-denied"),
        ("operation not permitted", "operation-not-permitted"),
        ("no such container", "container-missing"),
        ("connection refused", "connection-refused"),
    ):
        if fragment in stderr.lower():
            return name
    return "unclassified-stderr" if stderr else "no-stderr"


def command(*args, data=None):
    operation = operation_name(args)
    try:
        result = subprocess.run(args, input=data, capture_output=True, text=True, timeout=20)  # noqa: S603
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{operation} timed out after 20 seconds") from None
    if result.returncode:
        raise RuntimeError(
            f"{operation} failed: exit {result.returncode}; {failure_class(result.stderr)}"
        )
    return result.stdout + result.stderr if args[:2] == ("docker", "logs") else result.stdout


def interrupted(_signal, _frame):
    raise RuntimeError("transport probe interrupted")


def inspect(name):
    return json.loads(command("docker", "inspect", name))[0]


def identity(container):
    return container["Id"], container["State"]["StartedAt"], container["RestartCount"]


def shared_addresses(pool, node):
    pools = pool["NetworkSettings"]["Networks"]
    nodes = node["NetworkSettings"]["Networks"]
    shared = set(pools) & set(nodes)
    if len(shared) != 1:
        raise RuntimeError("probe requires one shared mining network")
    network = shared.pop()
    return pools[network]["IPAddress"], nodes[network]["IPAddress"]


def aux_transitions(log):
    return [int(value) for value in re.findall(r"update_aux_data: n_aux_chains = (\d+)", log)]


def configured_loglevel(container):
    args = list(container["Config"]["Cmd"])
    for value in container["Config"]["Env"]:
        if value.startswith("P2POOL_FLAGS="):
            args += shlex.split(value.split("=", 1)[1])
    level = 3
    for index, value in enumerate(args[:-1]):
        if value == "--loglevel":
            level = int(args[index + 1])
    return level


class Stratum:
    def __init__(self, address):
        self.socket = socket.create_connection((address, 3333), timeout=5)
        self.buffer = b""
        self.jobs = 0
        self.logged_in = False
        self.socket.sendall(
            json.dumps(
                {"id": 1, "method": "login", "params": {"login": "tari-gate-probe"}}
            ).encode()
            + b"\n"
        )

    def sample(self):
        self.socket.sendall(b'{"id":2,"method":"keepalived","params":{}}\n')
        while select.select([self.socket], [], [], 0)[0]:
            data = self.socket.recv(65536)
            if not data:
                raise RuntimeError("Monero stratum connection closed")
            self.buffer += data
            if len(self.buffer) > 2 * 1024 * 1024:
                raise RuntimeError("oversized stratum response")
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("error"):
                    raise RuntimeError("stratum request rejected")
                if message.get("id") == 1:
                    self.logged_in = bool(message.get("result", {}).get("job"))
                if message.get("method") == "job" or message.get("result", {}).get("job"):
                    self.jobs += 1

    def close(self):
        self.socket.close()


class Probe:
    def __init__(self, cleanup=False):
        self.pool = inspect("p2pool")
        self.pid = str(self.pool["State"]["Pid"])
        mount = next(item for item in self.pool["Mounts"] if item["Destination"] == "/stats")
        self.stats = Path(mount["Source"]) / "local"
        self.console = json.loads((self.stats / "console").read_text())
        self.stratum = None
        self.armed = False
        self.sample_count = 0
        self.original_loglevel = configured_loglevel(self.pool)
        self.aux_state = None
        if not cleanup:
            self.proxy = inspect("xmrig-proxy")
            self.pool_ip, self.node_ip = shared_addresses(self.pool, inspect("tari"))

    def loglevel(self, level):
        command(
            "docker",
            "exec",
            "-i",
            "p2pool",
            "bash",
            "-c",
            'IFS= read -r line; printf "%s\\n" "$line" > /dev/tcp/127.0.0.1/"$1"',
            "bash",
            str(self.console["tcp_port"]),
            data=self.console["cookie"] + f"loglevel {level}\n",
        )

    def rule(self, operation):
        return command(
            "sudo",
            "-n",
            "nsenter",
            "-t",
            self.pid,
            "-n",
            "iptables",
            operation,
            "OUTPUT",
            "-p",
            "tcp",
            "-d",
            self.node_ip,
            "--dport",
            "18142",
            "-m",
            "comment",
            "--comment",
            TAG,
            "-j",
            "REJECT",
            "--reject-with",
            "tcp-reset",
        )

    def mining(self):
        result = command(
            "docker",
            "exec",
            "dashboard",
            "python3",
            "-c",
            "import json; from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient; "
            "from mining_dashboard.config.config import PROXY_HOST,PROXY_API_PORT,PROXY_AUTH_TOKEN,ENABLE_XVB; "
            "s=XMRigProxyClient(PROXY_HOST,PROXY_API_PORT,PROXY_AUTH_TOKEN).get_summary(); "
            "print(json.dumps({'workers':s['miners']['now'],'xvb':ENABLE_XVB,"
            "'accepted':s['results']['accepted'],'hashes':s['results']['hashes_total']}))",
        )
        sample = json.loads(result)
        if sample["workers"] != 1 or sample["xvb"]:
            raise RuntimeError("probe requires exactly one borrowed miner with XvB disabled")
        return sample

    def sample(self):
        for name, baseline in (("p2pool", self.pool), ("xmrig-proxy", self.proxy)):
            actual = inspect(name)
            if not actual["State"]["Running"] or identity(actual) != identity(baseline):
                raise RuntimeError("a Monero mining container stopped or restarted")
        self.stratum.sample()
        self.sample_count += 1

    def wait(self, predicate, timeout=TIMEOUT):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.sample()
            if predicate():
                return
            time.sleep(2)
        raise RuntimeError("transport transition did not converge within its bound")

    def channel(self):
        chain = json.loads((self.stats / "merge_mining").read_text())["chains"][0]
        return chain["channel_state"]

    def transition(self, blocked, expected_aux):
        if self.aux_state != 1 - expected_aux:
            raise RuntimeError("opposite live aux-template baseline was not established")
        start = time.monotonic()
        since = datetime.datetime.now(datetime.UTC).isoformat()
        if blocked:
            self.armed = True
            self.rule("-I")
        else:
            self.rule("-D")
            self.armed = False
        last = {"channel": None, "aux_transitions": []}

        def completed():
            log = command("docker", "logs", "--since", since, "--tail", "2000", "p2pool")
            transitions = aux_transitions(log)
            channel = self.channel()
            last.update(channel=channel, aux_transitions=transitions)
            channel_ok = channel != "READY" if blocked else channel == "READY"
            if not channel_ok or not transitions or transitions[-1] != expected_aux:
                return False
            return True

        try:
            self.wait(completed)
        except RuntimeError:
            print(f"INFO unresolved transport transition: {json.dumps(last)}", flush=True)
            raise
        changed_after = time.monotonic() - start
        self.aux_state = expected_aux
        before = self.mining()
        window_start = time.monotonic()
        observed = []

        def mining_continues():
            if not completed():
                raise RuntimeError("aux-template state changed during the mining window")
            after = self.mining()
            observed[:] = [after]
            if after["accepted"] < before["accepted"] or after["hashes"] < before["hashes"]:
                raise RuntimeError("mining counters reset during the transport transition")
            return (
                time.monotonic() - window_start >= 30
                and after["accepted"] > before["accepted"]
                and after["hashes"] > before["hashes"]
            )

        self.wait(mining_continues, timeout=max(0, TIMEOUT - (time.monotonic() - start)))
        result = {
            "seconds": round(time.monotonic() - start, 3),
            "aux_transition_seconds": round(changed_after, 3),
            "mining_window_seconds": round(time.monotonic() - window_start, 3),
            "accepted_delta": observed[0]["accepted"] - before["accepted"],
            "hashes_delta": observed[0]["hashes"] - before["hashes"],
            "new_aux_chains": expected_aux,
        }
        label = "suppression" if blocked else "resumption"
        print(f"INFO {label}: {json.dumps(result, sort_keys=True)}", flush=True)
        print(
            f"ROW PASS {label} changes live aux templates while Monero shares advance", flush=True
        )

    def restore(self):
        try:
            rules = command(
                "sudo", "-n", "nsenter", "-t", self.pid, "-n", "iptables", "-S", "OUTPUT"
            )
            for line in rules.splitlines():
                args = shlex.split(line)
                if args[:1] == ["-A"] and "--comment" in args:
                    if args[args.index("--comment") + 1] == TAG:
                        command(
                            "sudo",
                            "-n",
                            "nsenter",
                            "-t",
                            self.pid,
                            "-n",
                            "iptables",
                            "-D",
                            *args[1:],
                        )
            remaining = command(
                "sudo", "-n", "nsenter", "-t", self.pid, "-n", "iptables", "-S", "OUTPUT"
            )
            if TAG in remaining:
                raise RuntimeError("transport fault remains after independent cleanup")
            self.armed = False
        finally:
            self.loglevel(self.original_loglevel)

    def run(self):
        rules = command("sudo", "-n", "nsenter", "-t", self.pid, "-n", "iptables", "-S", "OUTPUT")
        if TAG in rules:
            raise RuntimeError("a transport fault already exists")
        self.mining()
        self.stratum = Stratum(self.pool_ip)
        try:
            self.wait(lambda: self.stratum.logged_in and self.channel() == "READY")
            self.loglevel(5)
            since = datetime.datetime.now(datetime.UTC).isoformat()

            def baseline():
                log = command("docker", "logs", "--since", since, "--tail", "2000", "p2pool")
                states = aux_transitions(log)
                return bool(states and states[-1] == 1 and self.channel() == "READY")

            self.wait(baseline)
            self.aux_state = 1
            self.transition(True, 0)
            self.transition(False, 1)
            print(
                f"ROW PASS one Monero stratum connection survives both transitions "
                f"({self.sample_count} continuity samples)",
                flush=True,
            )
        finally:
            try:
                if self.armed:
                    self.rule("-D")
                    self.armed = False
            finally:
                try:
                    self.loglevel(self.original_loglevel)
                finally:
                    self.stratum.close()
        rules = command("sudo", "-n", "nsenter", "-t", self.pid, "-n", "iptables", "-S", "OUTPUT")
        if TAG in rules:
            raise RuntimeError("transport fault rule remains after cleanup")
        print("ROW PASS Tari transport fault removed", flush=True)


def main(args):
    try:
        if args == ["cleanup"]:
            Probe(cleanup=True).restore()
        elif args:
            raise RuntimeError("unsupported transport probe action")
        else:
            Probe().run()
    except Exception as exc:
        reason = str(exc) if type(exc) is RuntimeError else type(exc).__name__
        print(f"ROW FAIL Tari transport probe: {reason}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    sys.exit(main(sys.argv[1:]))
