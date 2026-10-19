import hashlib
import json
import os
import re
import tempfile
from pathlib import Path

NAME = "wallet-fixture-recovery.json"
HEX64 = re.compile(r"[0-9a-f]{64}")
FIELDS = {"schema", "job", "snapshot", "baseline", "state_fingerprint", "verdict"}


def state_fingerprint(state):
    data = {key: value for key, value in state.items() if key != "stage"}
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate recovery proof field")
        result[key] = value
    return result


def read(fixture, retire, job, directory, baseline, state, expected, validate):
    target = job / NAME
    if not target.exists() and not target.is_symlink():
        return None
    record = json.loads(retire.read_private(fixture, target), object_pairs_hook=unique)
    if (
        not isinstance(record, dict)
        or set(record) != FIELDS
        or type(record["schema"]) is not int
        or record["schema"] != 1
        or record["job"] != str(job.resolve())
        or record["snapshot"] != str(directory.resolve())
        or record["baseline"] != str(baseline)
        or record["state_fingerprint"] != state_fingerprint(state)
        or state["stage"] not in {"import_verified", "ready"}
    ):
        raise ValueError("recovery proof binding differs")
    verdict = record["verdict"]
    validate(verdict)
    request, archive, keys = expected
    if (
        verdict["request"] != request
        or verdict["proof"]["archive_fingerprint"] != archive
        or verdict["proof"]["keys_fingerprint"] != keys
    ):
        raise ValueError("recovery proof request or snapshot differs")
    return verdict


def publish(fixture, job, directory, baseline, state, verdict):
    record = {
        "schema": 1,
        "job": str(job.resolve()),
        "snapshot": str(directory.resolve()),
        "baseline": str(baseline),
        "state_fingerprint": state_fingerprint(state),
        "verdict": verdict,
    }
    descriptor, name = tempfile.mkstemp(prefix=".wallet-recovery-", dir=job)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(record, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        Path(name).replace(job / NAME)
        fixture.sync_directory(job)
    finally:
        Path(name).unlink(missing_ok=True)


def seal(fixture, directory, baseline, job, receipt, stage, ready_from_not_proven):
    if receipt == b"VERIFIED\n":
        if stage != "ready" or {p.name for p in directory.iterdir()} != {"state.json"}:
            raise ValueError("completed recovery has inconsistent cleanup")
        return
    if receipt == b"NOT_PROVEN\n":
        ready_from_not_proven(fixture, job)
    else:
        fixture.receipt(job, "READY")
    fixture.cleanup(directory, baseline)
    fixture.receipt(job, "VERIFIED")


def fingerprints(fixture, state):
    """The verdict's archive and keys digests, from a snapshot that names exactly one prepared pair."""
    keys = state["contents"][fixture.wallet_keys(state["contents"])]
    result = (state["archive_sha256"], keys[2] if len(keys) > 2 else None)
    if any(not isinstance(value, str) or not HEX64.fullmatch(value) for value in result):
        raise ValueError("recorded wallet fingerprint is malformed")
    return result
