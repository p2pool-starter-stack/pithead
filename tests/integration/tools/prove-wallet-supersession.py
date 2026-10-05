"""Lifecycle proof using a separate retained snapshot, never a recovery job's evidence."""

import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from contextlib import redirect_stdout
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, LIB / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def prove(baseline):
    fixture = load("fixture", "wallet-fixture.py")
    retirement = load("retirement", "wallet_fixture_supersession.py")
    if fixture.identity(baseline) is None:
        raise ValueError("lifecycle supersession proof requires a prepared wallet")
    scratch = Path(
        tempfile.mkdtemp(
            prefix="pithead-wallet-supersession-proof-", dir=os.environ["IT_SCRATCH_DIR"]
        )
    )
    # Retain this proof's archives privately, just like the recovery evidence.
    os.environ["IT_SCRATCH_DIR"] = str(scratch)
    with redirect_stdout(io.StringIO()) as output:
        fixture.capture(baseline)
    snapshot = Path(output.getvalue().strip())
    job = scratch / "1"
    job.mkdir()
    fixture.receipt(job, "ARMED")
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
    before = {p.name: fixture.digest(p) for p in snapshot.iterdir()}
    state = fixture.load(snapshot, baseline)
    # Exercise the real offline opener even when encrypted keys match. Unit
    # tests independently require both fields and drive differing ciphertext.
    first = retirement.open_copy(
        fixture, state["image"], snapshot / "wallet.tar", snapshot, "proof-a"
    )
    second = retirement.open_copy(
        fixture, state["image"], snapshot / "wallet.tar", snapshot, "proof-b"
    )
    if first != second:
        raise ValueError("isolated copies did not prove equal address and view key")
    result = retirement.supersede(fixture, snapshot, baseline, job, request)
    if (
        result["proof"]["encrypted_keys_match"] is not True
        or result["proof"]["identity_proven"] is not True
    ):
        raise ValueError("live fixture identity was not proved")
    if retirement.supersede(fixture, snapshot, baseline, job, request) != result:
        raise ValueError("supersession retry changed its result")
    if (job / "wallet-fixture-restore.state").read_bytes() != b"ARMED\n" or any(
        fixture.digest(snapshot / name) != digest for name, digest in before.items()
    ):
        raise ValueError("supersession changed the original evidence")
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


if __name__ == "__main__":
    os.umask(0o077)
    load("retirement", "wallet_fixture_supersession.py").install_signal_handlers()
    try:
        print(json.dumps(prove(Path(sys.argv[1]).resolve()), sort_keys=True))
    except (ValueError, OSError, subprocess.SubprocessError, tarfile.TarError, KeyError, TypeError):
        print(json.dumps({"schema": 1, "identity_proven": False}))
        sys.exit(1)
