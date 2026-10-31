"""Lifecycle proof of the real wallet recovery path on a separate private snapshot."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from contextlib import redirect_stdout
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
LIB = TOOLS.parent / "lib"
RECEIPT = "wallet-fixture-restore.state"
VERIFIED = hashlib.sha256(b"VERIFIED\n").hexdigest()
RECOVERY_TIMEOUT = 7200
REPLAY_TIMEOUT = 300
STOP_GRACE = 900
LIVE_METHODS = {"encrypted_keys", "isolated_open"}
REASONS = {
    "request",
    "evidence",
    "superseded",
    "receipt",
    "helper",
    "identity",
    "archive",
    "pair",
    "busy",
    "lock",
    "import",
    "startup",
    "readiness",
    "verdict",
    "seal",
    "interrupted",
    "internal",
}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


supersession = load("supersession_proof", TOOLS / "prove-wallet-supersession.py")


class ProofFailure(Exception):
    def __init__(self, reason, **extra):
        super().__init__(reason)
        self.reason = reason
        self.extra = extra


def recovery_environment(scratch):
    env = dict(os.environ)
    if env.get("RIG_LOCK_PARENT_ACTOR") or env.get("RIG_LOCK_PARENT_NONCE"):
        fd = env.get("RIG_LOCK_PARENT_FD", "")
        return env, (int(fd),) if fd.isdigit() and int(fd) > 2 else ()
    # The harness already holds the rig lock, so the recovery locks a private file instead.
    env["RIG_LOCK_FILE"] = str(scratch / "recovery.lock")
    return env, ()


def run_recovery(baseline, snapshot, job, raw, scratch, timeout, log):
    """Run the documented operator entry point; return its exit code and stdout."""
    env, pass_fds = recovery_environment(scratch)
    command = [  # noqa: S607 -- the documented operator command, resolved on the bench.
        "python3",
        str(LIB / "wallet_fixture_recovery.py"),
        str(baseline),
        str(snapshot),
        str(job),
    ]
    with log.open("ab") as stderr:
        process = subprocess.Popen(  # noqa: S603
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr,
            env=env,
            pass_fds=pass_fds,
        )
        try:
            out, _ = process.communicate(raw, timeout=timeout)
        except BaseException:
            # SIGTERM keeps the recovery retryable; a kill could damage the import.
            process.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=STOP_GRACE)
            process.stdin.close()
            process.stdout.close()
            raise
    return process.returncode, out


def refusal_reason(out):
    try:
        value = json.loads(out)
    except ValueError:
        return "unknown"
    reason = value.get("reason") if isinstance(value, dict) else None
    return reason if isinstance(reason, str) and reason in REASONS else "unknown"


def check_cleanup(fixture, scratch, snapshot, job):
    state = json.loads((snapshot / "state.json").read_text())
    helpers = fixture.docker(
        "ps",
        "-aq",
        "--filter",
        f"name=^/{re.escape(snapshot.name)}-",
        stdout=subprocess.PIPE,
        timeout=30,
    ).stdout.strip()
    if (
        {p.name for p in snapshot.iterdir()} != {"state.json"}
        or state["stage"] != "ready"
        or {p.name for p in job.iterdir()} != {RECEIPT, "wallet-fixture-recovery.json"}
        or list(scratch.glob("pithead-wallet-proof-*"))
        or helpers
    ):
        raise ProofFailure("cleanup_incomplete")


def check_verdict(recovery, fixture, out, request, before):
    try:
        verdict = json.loads(out)
        recovery.validate_verdict(verdict)
    except (ValueError, KeyError, TypeError):
        raise ProofFailure("verdict_invalid") from None
    proof = verdict["proof"]
    keys = before["contents"][fixture.wallet_keys(before["contents"])][2]
    if (
        verdict["request"] != request
        or proof["archive_fingerprint"] != before["archive_sha256"]
        or proof["keys_fingerprint"] != keys
    ):
        raise ProofFailure("verdict_mismatch")
    if proof["method"] not in LIVE_METHODS:
        raise ProofFailure("live_identity_unproven")
    return proof["method"]


def prove(baseline, progress, context):
    fixture = load("fixture", LIB / "wallet-fixture.py")
    recovery = load("recovery", LIB / "wallet_fixture_recovery.py")
    progress("configured_identity")
    if fixture.identity(baseline) is None:
        raise ValueError("lifecycle recovery proof requires a prepared wallet")
    progress("scratch")
    scratch = Path(
        tempfile.mkdtemp(prefix="pithead-wallet-recovery-proof-", dir=os.environ["IT_SCRATCH_DIR"])
    )
    # Retain this proof's archives privately: a failed run keeps them for an exact retry.
    os.environ["IT_SCRATCH_DIR"] = str(scratch)
    log = scratch / "recovery.log"
    context["log"] = str(log)
    progress("prepared_capture")
    supersession.wait_prepared(fixture, baseline)
    progress("capture")
    with redirect_stdout(io.StringIO()) as output:
        fixture.capture(baseline, diagnostics=False)
    snapshot = Path(output.getvalue().strip())
    progress("original_receipt")
    job = scratch / "1"
    job.mkdir()
    fixture.receipt(job, "ARMED")
    progress("receipt_fence")
    # VERIFIED is reachable only from READY, so a VERIFIED receipt after the run proves READY ran.
    try:
        fixture.receipt(job, "VERIFIED")
    except ValueError:
        pass
    else:
        raise ProofFailure("receipt_fence_open")
    if (job / RECEIPT).read_bytes() != b"ARMED\n":
        raise ProofFailure("receipt_fence_open")
    progress("commit_reference")
    commit = subprocess.check_output(  # noqa: S603 -- fixed checkout metadata command.
        ["git", "-C", str(baseline), "rev-parse", "HEAD"],  # noqa: S607 -- standard Git tool.
        text=True,
    ).strip()
    request = {
        "schema": 1,
        "original_job": 1,
        "original_commit": commit,
        "recovery_issues": ["pithead#3483"],
    }
    raw = json.dumps(request).encode()
    progress("snapshot_state")
    before = json.loads((snapshot / "state.json").read_text())
    progress("prepared_recovery")
    supersession.wait_prepared(fixture, baseline)
    progress("recover")
    code, out = run_recovery(baseline, snapshot, job, raw, scratch, RECOVERY_TIMEOUT, log)
    if code != 0:
        raise ProofFailure("recovery_refused", recovery_reason=refusal_reason(out))
    progress("verdict")
    method = check_verdict(recovery, fixture, out, request, before)
    progress("receipt")
    if (job / RECEIPT).read_bytes() != b"VERIFIED\n":
        raise ProofFailure("receipt_not_verified")
    progress("cleanup")
    check_cleanup(fixture, scratch, snapshot, job)
    progress("exact_replay")
    original = json.loads(out)
    code, out = run_recovery(baseline, snapshot, job, raw, scratch, REPLAY_TIMEOUT, log)
    if code != 0 or json.loads(out) != original:
        raise ProofFailure("replay_not_exact")
    return {
        "schema": 1,
        "restore_proven": True,
        "method": method,
        "live_identity_proven": True,
        "import_verified": True,
        "wallet_ready": True,
        "receipt_verified": True,
        "ready_fence_proven": True,
        "cleanup_proven": True,
        "replay_proven": True,
    }


def run_proof(baseline):
    stage = "load_helpers"
    context = {}

    def progress(value):
        nonlocal stage
        stage = value
        print(f"wallet recovery proof: {value}", file=sys.stderr, flush=True)

    try:
        return 0, prove(baseline, progress, context)
    except (
        ValueError,
        OSError,
        subprocess.SubprocessError,
        tarfile.TarError,
        KeyError,
        TypeError,
        ProofFailure,
    ) as error:
        # Fixed labels only, never exception text or wallet data; the log path is for a redacted tail.
        reason = (
            error.reason if isinstance(error, ProofFailure) else supersession.failure_reason(error)
        )
        if isinstance(error, InterruptedError):
            reason = "interrupted"
        extra = error.extra if isinstance(error, ProofFailure) else {}
        return 1, {
            "schema": 1,
            "restore_proven": False,
            "failed_stage": stage,
            "failure_reason": reason,
            **extra,
            **context,
        }


if __name__ == "__main__":
    os.umask(0o077)
    load("retirement", LIB / "wallet_fixture_supersession.py").install_signal_handlers()
    code, result = run_proof(Path(sys.argv[1]).resolve())
    print(json.dumps(result, sort_keys=True))
    sys.exit(code)
