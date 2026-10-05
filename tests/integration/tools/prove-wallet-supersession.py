"""Lifecycle proof using a separate retained snapshot, never a recovery job's evidence."""

import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import time
from contextlib import redirect_stdout
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, LIB / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def wait_prepared(fixture, baseline):
    # Compose health can mean scan grace, not a prepared cache. Never stop during
    # that grace: the existing capture guard must remain authoritative afterward.
    item = fixture.wallet_container({baseline}, timeout=30)
    if item is None or not item["State"]["Running"]:
        raise ValueError("prepared proof wallet is not running")
    deadline = time.monotonic() + 1200
    while (remaining := deadline - time.monotonic()) > 0:
        result = fixture.docker(
            "exec",
            item["Id"],
            "test",
            "!",
            "-e",
            f"{fixture.WALLET_DIR}/.payout-scanning",
            check=False,
            stdout=subprocess.DEVNULL,
            timeout=min(30, remaining),
        )
        if result.returncode == 0:
            return
        time.sleep(min(15, max(0, deadline - time.monotonic())))
    raise ValueError("prepared proof wallet scan deadline exceeded")


def failure_reason(error):
    # Exact known guard messages map to fixed labels; unknown input is discarded.
    guards = {
        "wallet consumer belongs to another checkout": "checkout_owner",
        "source container wallet identity differs from the baseline": "configured_identity",
        "wallet volume has another consumer": "extra_consumer",
        "prepared proof wallet scan deadline exceeded": "scan_deadline",
        "prepared proof wallet is not running": "wallet_not_running",
    }
    if isinstance(error, ValueError):
        return guards.get(str(error), "validation_refused")
    if isinstance(error, subprocess.TimeoutExpired):
        return "command_timeout"
    if isinstance(error, subprocess.CalledProcessError):
        return "command_failed"
    return "evidence_unavailable"


def prove(baseline, progress):
    fixture = load("fixture", "wallet-fixture.py")
    retirement = load("retirement", "wallet_fixture_supersession.py")
    progress("configured_identity")
    if fixture.identity(baseline) is None:
        raise ValueError("lifecycle supersession proof requires a prepared wallet")
    progress("scratch")
    scratch = Path(
        tempfile.mkdtemp(
            prefix="pithead-wallet-supersession-proof-", dir=os.environ["IT_SCRATCH_DIR"]
        )
    )
    # Retain this proof's archives privately, just like the recovery evidence.
    os.environ["IT_SCRATCH_DIR"] = str(scratch)
    progress("prepared_capture")
    wait_prepared(fixture, baseline)
    progress("capture")
    with redirect_stdout(io.StringIO()) as output:
        fixture.capture(baseline, diagnostics=False)
    snapshot = Path(output.getvalue().strip())
    progress("original_receipt")
    job = scratch / "1"
    job.mkdir()
    fixture.receipt(job, "ARMED")
    progress("commit_reference")
    commit = subprocess.check_output(  # noqa: S603 -- fixed checkout metadata command.
        ["git", "-C", str(baseline), "rev-parse", "HEAD"],  # noqa: S607 -- standard Git tool.
        text=True,
    ).strip()
    request = json.dumps(
        {
            "schema": 1,
            "original_job": 1,
            "original_commit": commit,
            "successor_job": 2,
            "successor_commit": commit,
            "recovery_issues": ["pithead#3133"],
        }
    ).encode()
    progress("original_fingerprints")
    before = {p.name: fixture.digest(p) for p in snapshot.iterdir()}
    progress("validate_snapshot")
    state = fixture.load(snapshot, baseline)
    # Exercise the real offline opener even when encrypted keys match. Unit
    # tests independently require both fields and drive differing ciphertext.
    progress("isolated_open_archive")
    first = retirement.open_copy(
        fixture, state["image"], snapshot / "wallet.tar", snapshot, "proof-a"
    )
    progress("isolated_open_control")
    second = retirement.open_copy(
        fixture, state["image"], snapshot / "wallet.tar", snapshot, "proof-b"
    )
    if first != second:
        raise ValueError("isolated copies did not prove equal address and view key")
    progress("prepared_supersession")
    wait_prepared(fixture, baseline)
    progress("supersede_live")
    result = retirement.supersede(fixture, snapshot, baseline, job, request)
    if (
        result["proof"]["encrypted_keys_match"] is not True
        or result["proof"]["identity_proven"] is not True
    ):
        raise ValueError("live fixture identity was not proved")
    progress("retry")
    if retirement.supersede(fixture, snapshot, baseline, job, request) != result:
        raise ValueError("supersession retry changed its result")
    progress("preserved_evidence")
    if (job / "wallet-fixture-restore.state").read_bytes() != b"ARMED\n" or any(
        fixture.digest(snapshot / name) != digest for name, digest in before.items()
    ):
        raise ValueError("supersession changed the original evidence")
    progress("replay_refusal")
    try:
        fixture.restore(snapshot, baseline, baseline)
    except ValueError:
        pass
    else:
        raise ValueError("supersession allowed restoration replay")
    return {
        "schema": 1,
        "identity_proven": True,
        "isolated_open_proven": True,
        "evidence_preserved": True,
        "idempotence_proven": True,
        "replay_refused": True,
    }


def run_proof(baseline):
    stage = "load_helpers"

    def progress(value):
        nonlocal stage
        stage = value

    try:
        return 0, prove(baseline, progress)
    except (
        ValueError,
        OSError,
        subprocess.SubprocessError,
        tarfile.TarError,
        KeyError,
        TypeError,
    ) as error:
        # Fixed stage labels only: never echo exceptions, wallet data or paths.
        return 1, {
            "schema": 1,
            "identity_proven": False,
            "failed_stage": stage,
            "failure_reason": failure_reason(error),
        }


if __name__ == "__main__":
    os.umask(0o077)
    load("retirement", "wallet_fixture_supersession.py").install_signal_handlers()
    code, result = run_proof(Path(sys.argv[1]).resolve())
    print(json.dumps(result, sort_keys=True))
    sys.exit(code)
