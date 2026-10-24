import ipaddress
import json
import re
import socket
import subprocess
import time
import uuid


def command(*args):
    try:
        result = subprocess.run(  # noqa: S603
            args,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("profile peering fixture command timed out") from None
    if result.returncode:
        raise RuntimeError("profile peering fixture command failed")
    return result.stdout.strip()


def inspect(name):
    return json.loads(command("docker", "inspect", name))[0]


def outgoing_onion(peers, target=None):
    return any(
        isinstance(peer, str)
        and peer.startswith("O,")
        and re.search(r"[a-z2-7]{56}\.onion(?::[0-9]+)?$", peer)
        and (target is None or target in peer.rsplit(",", 1)[-1])
        for peer in peers
    )


def probe(container, address, port):
    ipaddress.IPv4Address(address)
    if port not in (37888, 37889, 37890):
        raise ValueError("invalid peering port")
    if container == "monerod":
        script = f"exec 3<>/dev/tcp/{address}/{port}; head -c 1 <&3 | wc -c"
        count = command("docker", "exec", container, "timeout", "8", "bash", "-ec", script)
    else:
        count = command(
            "docker",
            "exec",
            container,
            "sh",
            "-c",
            f"timeout 8 nc -w 4 {address} {port} </dev/null | head -c 1 | wc -c",
        )
    if count not in ("0", "1"):
        raise RuntimeError("invalid peering probe result")
    return count == "1"


def diagnostics(name, stats_path):
    result = {}
    try:
        state = inspect(name)["State"]
        result.update(running=bool(state["Running"]), exit_code=int(state["ExitCode"]))
    except (RuntimeError, ValueError, KeyError, TypeError):
        result["state_unavailable"] = True
    try:
        peers = json.loads(command("docker", "exec", name, "cat", stats_path))["peers"]
        result.update(
            stats_available=True,
            inbound=sum(isinstance(p, str) and p.startswith("I,") for p in peers),
            outbound_onion=outgoing_onion(peers),
        )
    except (RuntimeError, ValueError, KeyError, TypeError):
        result["stats_available"] = False
    try:
        logs = command("docker", "logs", "--tail", "100", name).lower()
        for category, pattern in (
            ("rpc_error", r"(?:rpc|zmq).*?(?:fail|error|refus|denied)"),
            ("data_api_error", r"(?:data.api|directory|file).*?(?:fail|error|denied|exist)"),
            ("option_error", r"(?:unknown|invalid|unrecognized).*?(?:option|argument)"),
            ("connect_error", r"(?:connect|handshake).*?(?:fail|error|refus|timed out)"),
        ):
            result[category] = bool(re.search(pattern, logs))
    except RuntimeError:
        result["logs_unavailable"] = True
    return result


def main():
    env = dict(line.split("=", 1) for line in open(".env") if "=" in line)
    env = {key: value.strip() for key, value in env.items()}
    port = int(env["P2POOL_PORT"])
    if env["PITHEAD_PROFILE"] != "privacy" or env["TOR_EGRESS_FIREWALL"] != "true":
        raise RuntimeError("Privacy firewall precondition missing")
    candidate = inspect("p2pool")
    tor = inspect("tor")
    network = next(iter(candidate["NetworkSettings"]["Networks"]))
    address = candidate["NetworkSettings"]["Networks"][network]["IPAddress"]
    if candidate["HostConfig"].get("PortBindings"):
        raise RuntimeError("P2Pool peering is published")
    if not probe("tor", address, port):
        raise RuntimeError("Tor cannot receive the P2Pool handshake challenge")
    argv = candidate["Config"]["Cmd"]

    def argument(flag):
        return argv[argv.index(flag) + 1]

    suffix = uuid.uuid4().hex[:12]
    client, peer = f"profile-tor-{suffix}", f"profile-peer-{suffix}"
    created = set()
    try:
        command(
            "docker",
            "run",
            "-d",
            "--name",
            client,
            "--entrypoint",
            "tor",
            tor["Config"]["Image"],
            "--SocksPort",
            "0.0.0.0:9050",
            "--DataDirectory",
            "/var/lib/tor/profile-client",
            "--Log",
            "notice stdout",
        )
        created.add(client)
        proxy_ip = inspect(client)["NetworkSettings"]["Networks"]["bridge"]["IPAddress"]
        ipaddress.IPv4Address(proxy_ip)
        deadline = time.monotonic() + 180
        while "Bootstrapped 100%" not in command("docker", "logs", client):
            if time.monotonic() >= deadline:
                raise RuntimeError("independent Tor client bootstrap deadline")
            time.sleep(5)
        if network not in inspect("monerod")["NetworkSettings"]["Networks"]:
            raise RuntimeError("non-Tor probe is not on the candidate network")
        if probe("monerod", address, port):
            raise RuntimeError("non-Tor bridge client received a handshake challenge")
        with socket.create_connection((address, port), timeout=5) as direct:
            direct.settimeout(5)
            if direct.recv(1):
                raise RuntimeError("direct bridge client received a handshake challenge")
        onion = env["P2POOL_ONION_ADDRESS"]
        if not re.fullmatch(r"[a-z2-7]{56}\.onion", onion):
            raise RuntimeError("invalid candidate onion")
        args = [
            "docker",
            "create",
            "--name",
            peer,
            "--network",
            "bridge",
            "-e",
            "TARI_MODE=off",
            "-e",
            f"P2POOL_FLAGS=--socks5 {proxy_ip}:9050 --socks5-proxy-type tor --no-dns",
            candidate["Config"]["Image"],
            "--host",
            argument("--host"),
            "--rpc-port",
            argument("--rpc-port"),
            "--rpc-login",
            argument("--rpc-login"),
            "--zmq-port",
            argument("--zmq-port"),
            "--wallet",
            argument("--wallet"),
            "--no-log-file",
            "--light-mode",
            "--no-clearnet-p2p",
            "--no-upnp",
            "--no-dns",
            "--socks5",
            f"{proxy_ip}:9050",
            "--socks5-proxy-type",
            "tor",
            "--addpeers",
            f"{onion}:{port}",
            "--local-api",
            "--data-api",
            "/home/ubuntu/profile-stats",
        ]
        if port == 37888:
            args.append("--mini")
        elif port == 37890:
            args.append("--nano")
        command(*args)
        created.add(peer)
        command("docker", "network", "connect", network, peer)
        command("docker", "start", peer)
        deadline = time.monotonic() + 600
        consecutive = 0
        while time.monotonic() < deadline:
            try:
                stats = json.loads(command("docker", "exec", "p2pool", "cat", "/stats/local/p2p"))
                remote = json.loads(
                    command(
                        "docker",
                        "exec",
                        peer,
                        "cat",
                        "/home/ubuntu/profile-stats/local/p2p",
                    )
                )
                accepted = (
                    outgoing_onion(stats["peers"])
                    and any(p.startswith("I,") for p in stats["peers"])
                    and outgoing_onion(remote["peers"], onion)
                )
            except (RuntimeError, ValueError, KeyError):
                accepted = False
            consecutive = consecutive + 1 if accepted else 0
            if consecutive >= 3:
                print(
                    "PASS: Privacy inbound and outbound onion peers completed handshakes; direct and non-Tor bridge access rejected"
                )
                return
            time.sleep(10)
        print(
            json.dumps(
                {
                    "candidate": diagnostics("p2pool", "/stats/local/p2p"),
                    "fixture": diagnostics(peer, "/home/ubuntu/profile-stats/local/p2p"),
                },
                sort_keys=True,
            ),
            flush=True,
        )
        raise RuntimeError("Privacy peer handshake deadline")
    finally:
        for name in (peer, client):
            cleanup = subprocess.run(  # noqa: S603
                ["docker", "rm", "-f", name],  # noqa: S607
                capture_output=True,
                timeout=60,
            )
            if name in created and cleanup.returncode:
                raise RuntimeError("profile peering fixture cleanup failed")


if __name__ == "__main__":
    main()
