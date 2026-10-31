"""Restore a retained wallet fixture for a finished job and prove the baseline wallet."""

import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
HELPER = HERE / "wallet-fixture-recovery.sh"
START_TIMEOUT = 3600
READY_TIMEOUT = 1800
RECEIPT = "wallet-fixture-restore.state"
STARTS = {b"ARMED\n", b"NOT_PROVEN\n", b"READY\n"}
VERIFIED = hashlib.sha256(b"VERIFIED\n").hexdigest()
LIVE_METHODS = {"encrypted_keys", "isolated_open"}
METHODS = LIVE_METHODS | {"empty_volume", "no_volume", "resumed"}
REQUEST_FIELDS = {"schema", "original_job", "original_commit", "recovery_issues"}
PROOF_FIELDS = {
    "method",
    "live_identity_proven",
    "import_verified",
    "wallet_ready",
    "archive_fingerprint",
    "keys_fingerprint",
}
VERDICT_FIELDS = {"schema", "request", "status", "proof", "receipt_fingerprint"}
HEX64 = re.compile(r"[0-9a-f]{64}")


class Refusal(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


@contextlib.contextmanager
def refusing(reason):
    try:
        yield
    except Refusal:
        raise
    except InterruptedError:
        raise Refusal("interrupted") from None
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
        tarfile.TarError,
    ) as error:
        print(f"wallet recovery refused: {reason} ({type(error).__name__})", file=sys.stderr)
        raise Refusal(reason) from None


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def request_data(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate recovery request field")
            result[key] = value
        return result

    if len(raw) > 16384:
        raise ValueError("recovery request exceeds its limit")
    data = json.loads(raw, object_pairs_hook=unique)
    if not isinstance(data, dict) or set(data) != REQUEST_FIELDS or type(data["schema"]) is not int:
        raise ValueError("invalid recovery request schema")
    job, commit, refs = data["original_job"], data["original_commit"], data["recovery_issues"]
    if data["schema"] != 1 or type(job) is not int or not 0 < job < 2**63:
        raise ValueError("invalid recovery job reference")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("invalid recovery commit reference")
    if (
        not isinstance(refs, list)
        or not 1 <= len(refs) <= 16
        or any(
            not isinstance(ref, str)
            or not re.fullmatch(r"(?:pithead|bench-ci)#[1-9][0-9]{0,9}", ref)
            for ref in refs
        )
        or len(set(refs)) != len(refs)
    ):
        raise ValueError("invalid recovery references")
    return data


def validate_verdict(verdict):
    proof = verdict.get("proof") if isinstance(verdict, dict) else None
    if (
        set(verdict) != VERDICT_FIELDS
        or verdict["schema"] != 1
        or verdict["status"] != "RESTORED"
        or verdict["receipt_fingerprint"] != VERIFIED
        or not isinstance(proof, dict)
        or set(proof) != PROOF_FIELDS
        or proof["method"] not in METHODS
        or proof["live_identity_proven"] is not (proof["method"] in LIVE_METHODS)
        or proof["import_verified"] is not True
        or proof["wallet_ready"] is not True
        or any(
            not isinstance(proof[key], str) or not HEX64.fullmatch(proof[key])
            for key in ("archive_fingerprint", "keys_fingerprint")
        )
    ):
        raise ValueError("invalid recovery verdict")
    request_data(json.dumps(verdict["request"]).encode())


def fingerprints(fixture, state):
    """The verdict's archive and keys digests, from a snapshot that names exactly one prepared pair."""
    keys = state["contents"][fixture.wallet_keys(state["contents"])]
    result = (state["archive_sha256"], keys[2] if len(keys) > 2 else None)
    if any(not isinstance(value, str) or not HEX64.fullmatch(value) for value in result):
        raise ValueError("recorded wallet fingerprint is malformed")
    return result


def hold_bench_lock():
    """Take the rig flock e2e.sh takes, unless the runner holds it and the helper verifies it."""
    if os.environ.get("RIG_LOCK_PARENT_ACTOR") or os.environ.get("RIG_LOCK_PARENT_NONCE"):
        return None
    path = os.environ.get("RIG_LOCK_FILE", "/var/lock/rig-e2e.lock")
    if os.path.islink(path):
        raise Refusal("busy")
    if not os.path.exists(path):
        with contextlib.suppress(OSError):
            Path(path).touch(mode=0o666)
            os.chmod(path, 0o666)  # noqa: S103  # shared readers must be able to join, as in rig_lock
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        raise Refusal("busy") from None
    return descriptor


class HelperSteps:
    """The steps that exist only as shell: verify the runner's lock, start the baseline, run the gate."""

    def __init__(self, baseline):
        self.baseline = str(baseline)

    def run(self, action, timeout):
        fd = os.environ.get("RIG_LOCK_PARENT_FD", "")
        process = subprocess.Popen(  # noqa: S603
            ["bash", str(HELPER), action, self.baseline],  # noqa: S607
            stdin=subprocess.DEVNULL,
            stdout=sys.stderr,
            stderr=sys.stderr,
            start_new_session=True,
            umask=0o022,
            pass_fds=(int(fd),) if fd.isdigit() and int(fd) > 2 else (),
        )
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        if code != 0:
            raise subprocess.CalledProcessError(code, action)

    def lock_check(self):
        self.run("lock-verify", 60)

    def start(self):
        self.run("start", START_TIMEOUT)

    def ready(self):
        self.run("ready", READY_TIMEOUT)


def live_method(fixture, retire, state, directory, baseline, branch):
    """Prove a live wallet is the snapshot's before its volume is overwritten."""
    names = fixture.docker(
        "volume",
        "ls",
        "-q",
        "--filter",
        f"name=^{fixture.VOLUME}$",
        stdout=subprocess.PIPE,
        timeout=30,
    ).stdout.split()
    if fixture.VOLUME.encode() not in names:
        return "no_volume"
    with (directory / "image.tar").open("rb") as stream:
        fixture.docker("image", "load", stdin=stream, stdout=subprocess.DEVNULL, timeout=180)
    if fixture.inspect("image", state["image"], timeout=30)["Id"] != state["image"]:
        raise ValueError("wallet helper image differs from its source")
    fixture.local_volume(timeout=30)
    try:
        found = fixture.docker(
            *fixture.helper(state["image"], True, directory, "recovery-probe"),
            f"find {fixture.WALLET_DIR} -mindepth 1 -maxdepth 1 -name 'payout-wallet*' -print -quit",
            stdout=subprocess.PIPE,
            timeout=120,
        ).stdout.strip()
    finally:
        fixture.cleanup_helper(f"{directory.name}-recovery-probe")
    if not found:
        return "empty_volume"
    return retire.prove_live(fixture, state, directory, baseline, branch)["method"]


def ready_from_not_proven(fixture, job):
    """The one receipt transition the state machine refuses elsewhere; only a full proof reaches it."""
    descriptor = os.open(job / RECEIPT, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        fixture.private(os.fstat(stream.fileno()))
        if stream.read(12) != b"NOT_PROVEN\n":
            raise ValueError("wallet restoration receipt changed")
    descriptor, name = tempfile.mkstemp(prefix=".wallet-fixture-", dir=job)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write("READY\n")
            stream.flush()
            os.fsync(stream.fileno())
        Path(name).replace(job / RECEIPT)
        fixture.sync_directory(job)
    finally:
        Path(name).unlink(missing_ok=True)


def evidence(fixture, retire, directory, job, request):
    info = job.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o022
        or job.name != str(request["original_job"])
    ):
        raise ValueError("recovery job directory is unsafe or mismatched")
    fixture.private(directory.lstat(), True)
    if (directory / "supersession.json").exists() or (directory / "supersession.json").is_symlink():
        raise Refusal("superseded")
    stage = json.loads(retire.read_private(fixture, directory / "state.json"))["stage"]
    if stage not in {"captured", "restoring", "import_verified", "ready"}:
        raise ValueError("wallet fixture stage is not recoverable")
    if stage != "ready":
        for name, limit in (("wallet.tar", 2 * 1024**3 + 1024**2), ("image.tar", 4 * 1024**3)):
            size = (directory / name).lstat()
            fixture.private(size)
            if size.st_size > limit:
                raise ValueError("wallet recovery archive exceeds its limit")
    return stage


def recover(fixture, retire, directory, baseline, job, raw, steps, branch):
    with refusing("request"):
        request = request_data(raw)
    with refusing("evidence"):
        stage = evidence(fixture, retire, directory, job, request)
    with refusing("receipt"):
        receipt = retire.read_private(fixture, job / RECEIPT, 11)
        if receipt not in STARTS:
            raise ValueError("wallet restoration receipt cannot be recovered")
    with refusing("identity"):
        configured = json.loads((directory / "state.json").read_bytes())["identity"]
        if configured != fixture.identity(baseline):
            raise ValueError("baseline wallet identity changed")
    with refusing("archive"):
        state = fixture.load(directory, baseline, cleanup_only=stage == "ready")
    with refusing("pair"):
        archive_fingerprint, keys_fingerprint = fingerprints(fixture, state)
    with refusing("helper"):
        helpers = fixture.docker(
            "ps",
            "-aq",
            "--filter",
            f"name=^/{re.escape(directory.name)}-",
            stdout=subprocess.PIPE,
            timeout=30,
        ).stdout.strip()
        if helpers:
            raise ValueError("a wallet fixture helper container is active")
    with refusing("lock"):
        steps.lock_check()
    method = "resumed"
    if stage != "ready":
        if stage == "captured":
            with refusing("identity"):
                method = live_method(fixture, retire, state, directory, baseline, branch)
        with refusing("import"):
            try:
                fixture.restore(directory, baseline, branch)
            finally:
                for action in ("import", "verify"):
                    fixture.cleanup_helper(f"{directory.name}-{action}")
    with refusing("startup"):
        steps.start()
    with refusing("readiness"):
        steps.ready()
    with refusing("lock"):
        steps.lock_check()
    verdict = {
        "schema": 1,
        "request": request,
        "status": "RESTORED",
        "proof": {
            "method": method,
            "live_identity_proven": method in LIVE_METHODS,
            "import_verified": True,
            "wallet_ready": True,
            "archive_fingerprint": archive_fingerprint,
            "keys_fingerprint": keys_fingerprint,
        },
        "receipt_fingerprint": VERIFIED,
    }
    with refusing("verdict"):
        validate_verdict(verdict)
    with refusing("seal"):
        if receipt == b"NOT_PROVEN\n":
            ready_from_not_proven(fixture, job)
        else:
            fixture.receipt(job, "READY")
        fixture.cleanup(directory, baseline)
        fixture.receipt(job, "VERIFIED")
    return verdict


def run(argv, raw, steps=None):
    """Return (exit code, stdout text); the text is one JSON object, a verdict or a fixed refusal."""
    lock = None
    try:
        if len(argv) != 3:
            raise Refusal("request")
        fixture = load_module("wallet_fixture", "wallet-fixture.py")
        retire = load_module("wallet_fixture_supersession", "wallet_fixture_supersession.py")
        baseline = Path(argv[0]).resolve()
        branch = Path(os.environ.get("E2E_DIR", "/srv/code/pithead-e2e")).resolve()
        lock = hold_bench_lock()
        verdict = recover(
            fixture,
            retire,
            Path(argv[1]),
            baseline,
            Path(argv[2]),
            raw,
            steps or HelperSteps(baseline),
            branch,
        )
    except Refusal as refusal:
        return 1, json.dumps({"schema": 1, "status": "REFUSED", "reason": refusal.reason})
    except InterruptedError:
        return 1, json.dumps({"schema": 1, "status": "REFUSED", "reason": "interrupted"})
    except Exception as error:  # noqa: BLE001
        print(f"wallet recovery failed: {type(error).__name__}", file=sys.stderr)
        return 1, json.dumps({"schema": 1, "status": "REFUSED", "reason": "internal"})
    finally:
        if lock is not None:
            os.close(lock)
    return 0, json.dumps(verdict, sort_keys=True)


if __name__ == "__main__":
    os.umask(0o077)
    load_module(
        "wallet_fixture_supersession", "wallet_fixture_supersession.py"
    ).install_signal_handlers()
    code, text = run(sys.argv[1:], sys.stdin.buffer.read(16385))
    print(text)
    sys.exit(code)
