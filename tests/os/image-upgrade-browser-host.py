#!/usr/bin/env python3
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack
from pathlib import Path
from urllib.parse import urlparse


class CleanupError(Exception):
    pass


def wait_until(check, attempts, interval):
    for _ in range(attempts):
        if check():
            return
        time.sleep(interval)
    raise TimeoutError("bounded wait expired")


def remove_container(cidfile, env=None):
    path = Path(cidfile)
    if not path.exists():
        return
    cid = path.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9a-f]{12,64}", cid):
        raise CleanupError("invalid container id")
    docker = shutil.which("docker", path=env.get("PATH") if env else None)
    if not docker:
        raise CleanupError("docker unavailable during cleanup")
    try:
        result = subprocess.run(  # noqa: S603
            [docker, "rm", "-f", cid],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CleanupError("container cleanup did not complete") from error
    if result.returncode != 0:
        raise CleanupError("container cleanup failed")
    path.unlink(missing_ok=True)


def stop_process(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def private_binary_file(path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    return os.fdopen(descriptor, "wb")


def diagnostic_excerpt(text, secrets):
    clean = re.sub(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\)|[@-_])", "", text)
    clean = "".join(
        character if character == "\n" or character.isprintable() else " " for character in clean
    )
    variants = {
        value for secret in secrets if secret for value in (secret, json.dumps(secret)[1:-1])
    }
    for secret in sorted(variants, key=len, reverse=True):
        clean = clean.replace(secret, "<redacted>")
    lines = [line.strip() for line in clean.splitlines() if line.strip()][-6:]
    excerpt = "\n".join(lines)
    return excerpt[:800]


def self_test():
    calls = 0

    def eventually_true():
        nonlocal calls
        calls += 1
        return calls == 2

    wait_until(eventually_true, 2, 0)
    try:
        wait_until(lambda: False, 1, 0)
        raise AssertionError("timeout was accepted")
    except TimeoutError:
        pass

    class Process:
        def __init__(self):
            self.actions = []
            self.running = True

        def poll(self):
            return None if self.running else 0

        def terminate(self):
            self.actions.append("terminate")

        def wait(self, timeout=None):
            if timeout is not None:
                raise subprocess.TimeoutExpired("fixture", timeout)
            self.actions.append("wait")
            self.running = False

        def kill(self):
            self.actions.append("kill")

    process = Process()
    stop_process(process)
    if process.actions != ["terminate", "kill", "wait"]:
        raise AssertionError(process.actions)

    with tempfile.TemporaryDirectory(prefix="pithead-browser-host-selftest.") as directory:
        root = Path(directory)
        bindir = root / "bin"
        bindir.mkdir()
        log = root / "docker.log"
        docker = bindir / "docker"
        docker.write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >"$TEST_LOG"\n', encoding="utf-8")
        docker.chmod(0o700)
        cidfile = root / "browser.cid"
        cidfile.write_text("a" * 64, encoding="utf-8")
        env = {"PATH": str(bindir), "TEST_LOG": str(log)}
        remove_container(cidfile, env)
        if log.read_text(encoding="utf-8").strip() != f"rm -f {'a' * 64}":
            raise AssertionError("container cleanup command mismatch")
        if cidfile.exists():
            raise AssertionError("cidfile survived cleanup")
        docker.write_text("#!/bin/sh\nexit 17\n", encoding="utf-8")
        failed = root / "failed.cid"
        failed.write_text("b" * 64, encoding="utf-8")
        log.unlink()
        try:
            remove_container(failed, env)
            raise AssertionError("failed Docker cleanup passed")
        except CleanupError:
            pass
        if not failed.exists():
            raise AssertionError("failed cleanup discarded its cidfile")
        secrets = [
            "admin",
            'admin-"secret',
            "https://private.example",
            "private.example",
            "/private/key",
            "/private/work",
            str(root),
        ]
        diagnostic = diagnostic_excerpt(
            "\x1b[31madmin\x1b[0m\x7f\x85\n"
            'admin-"secret admin-\\"secret\nhttps://private.example /private/key /private/work\n',
            secrets,
        )
        forbidden = [*secrets, json.dumps(secrets[1])[1:-1], "secret", "\x1b", "\x7f", "\x85"]
        if any(value in diagnostic for value in forbidden):
            raise AssertionError("diagnostic leaked private input")
        if diagnostic.count("<redacted>") != 6:
            raise AssertionError("diagnostic redaction coverage missing")
        diagnostic = diagnostic_excerpt(
            "\n".join(f"line-{number}-{'x' * 200}" for number in range(10)), secrets
        )
        if len(diagnostic) > 800 or len(diagnostic.splitlines()) > 6:
            raise AssertionError("diagnostic was not bounded")
    print("image-upgrade-browser-host self-test: PASS")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return 0
    if len(sys.argv) != 5:
        return 2
    origin, key, work, iface = sys.argv[1:]
    credentials = sys.stdin.read()
    parsed_credentials = json.loads(credentials)
    if not parsed_credentials.get("username") or not parsed_credentials.get("password"):
        return 2
    if not re.fullmatch(r"[a-zA-Z0-9_.-]+", iface):
        return 2
    host = urlparse(origin).hostname
    if not host:
        return 2
    ssh_binary = shutil.which("ssh")
    docker_binary = shutil.which("docker")
    if not ssh_binary or not docker_binary:
        return 2
    ssh_args = [
        ssh_binary,
        "-i",
        key,
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=5",
        f"root@{host}",
    ]

    def ssh(command):
        return subprocess.run(  # noqa: S603
            [*ssh_args, command],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip()

    process = None
    stage = "initial-ssh"
    host_directory = Path(tempfile.mkdtemp(prefix="pithead-browser-host."))
    host_directory.chmod(0o700)
    cidfile = host_directory / "browser.cid"
    stdout_path = host_directory / "browser.stdout"
    stderr_path = host_directory / "browser.stderr"
    result = 1
    cleanup_failed = False
    raw_stderr = b""

    def interrupted(signum, frame):
        raise InterruptedError

    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        previous_boot = ssh("cat /proc/sys/kernel/random/boot_id")
        stage = "browser-start"
        with ExitStack() as files:
            stdout_file = files.enter_context(private_binary_file(stdout_path))
            stderr_file = files.enter_context(private_binary_file(stderr_path))
            process = subprocess.Popen(  # noqa: S603
                [
                    docker_binary,
                    "run",
                    "--network",
                    "host",
                    "--ipc",
                    "host",
                    "--cidfile",
                    str(cidfile),
                    "-i",
                    "-v",
                    f"{work}:/work",
                    "-w",
                    "/work",
                    "mcr.microsoft.com/playwright@sha256:06a9939e57531807f8d5fd76ce44b53165ffb7d7501d87ab10e285c20b1e971f",
                    "bash",
                    "-lc",
                    'npm ci --ignore-scripts >/dev/null </dev/null && node image-upgrade-browser.mjs "$1"',
                    "_",
                    origin,
                ],
                stdin=subprocess.PIPE,
                stdout=stdout_file,
                stderr=stderr_file,
            )
            process.stdin.write(credentials.encode("utf-8"))
            process.stdin.close()
        stage = "reboot-request"

        def reboot_requested():
            if process.poll() is not None:
                raise RuntimeError("browser exited before reboot")
            return Path(work, "restore-request").exists()

        wait_until(reboot_requested, 240, 5)
        stage = "new-boot-observation"

        def new_boot_ready():
            try:
                command = (
                    f'test "$(cat /proc/sys/kernel/random/boot_id)" != "{previous_boot}" '
                    f"&& ! ip -6 address show dev {iface} | grep -qi 'fd00:2463::1' "
                    "&& systemctl is-active --quiet pithead-boot.service "
                    '&& test "$(systemctl show -p Result --value pithead-boot.service)" = success '
                    "&& podman ps --format '{{.Names}}' | grep -qx caddy && echo ready"
                )
                return ssh(command) == "ready"
            except (OSError, subprocess.SubprocessError):
                return False

        wait_until(new_boot_ready, 240, 5)
        stage = "san-restore"
        ssh(
            f"ip -6 address replace fd00:2463::1/128 dev {iface} "
            "&& systemctl start pithead-address-watch.service"
        )

        def san_restored():
            try:
                ssh("systemctl start pithead-address-watch.service")
                return (
                    ssh(
                        "openssl x509 -in /data/pithead/data/tls/wizard.crt -noout "
                        "-ext subjectAltName | grep -qi 'FD00:2463' && echo ready"
                    )
                    == "ready"
                )
            except (OSError, subprocess.SubprocessError):
                return False

        wait_until(san_restored, 60, 5)
        Path(work, "restore-complete").write_text(
            "new_boot=true transient_san_absent=true initial_render=true restored_san=true\n",
            encoding="utf-8",
        )
        stage = "browser-verdict"
        if process.wait(timeout=1500) != 0:
            raise RuntimeError("browser failed")
        output = stdout_path.read_text(encoding="utf-8", errors="replace")
        print(
            "new boot observation: transient_san_absent=true initial_render=true restored_san=true"
        )
        print(output, end="")
        result = 0
    except (OSError, subprocess.SubprocessError, TimeoutError, RuntimeError, InterruptedError):
        result = 1
    finally:
        try:
            stop_process(process)
        except (OSError, subprocess.SubprocessError):
            cleanup_failed = True
        try:
            remove_container(cidfile)
        except CleanupError:
            cleanup_failed = True
        if stderr_path.exists():
            raw_stderr = stderr_path.read_bytes()[-65536:]
        if result != 0 and raw_stderr:
            with private_binary_file(host_directory / "browser-stderr.log") as destination:
                destination.write(raw_stderr)
        if cleanup_failed:
            result = 1
        if result != 0:
            secrets = [
                parsed_credentials.get("username", ""),
                parsed_credentials.get("password", ""),
                origin,
                host,
                key,
                work,
                str(host_directory),
            ]
            excerpt = diagnostic_excerpt(raw_stderr.decode("utf-8", errors="replace"), secrets)
            exit_code = process.returncode if process else "not-started"
            cleanup = "failed" if cleanup_failed else "complete"
            print(
                f"browser diagnostic stage={stage} exit={exit_code} cleanup={cleanup}",
                file=sys.stderr,
            )
            if excerpt:
                print(excerpt, file=sys.stderr)
        if not cleanup_failed and (result == 0 or not raw_stderr):
            shutil.rmtree(host_directory)
    return result


if __name__ == "__main__":
    sys.exit(main())
