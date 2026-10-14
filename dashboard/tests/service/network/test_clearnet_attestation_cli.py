"""CLI status rejects replayed dashboard markers even when inode and ctime collide."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]


@pytest.mark.parametrize("chain", ["monero", "tari"])
@pytest.mark.parametrize(
    "uid,mode,expected",
    [(0, 0o644, True), (1000, 0o644, False), (0, 0o664, False), (0, 0o646, False)],
)
@pytest.mark.parametrize("ctime_changed", [False, True])
def test_cli_attestation_requires_host_claim(tmp_path, chain, uid, mode, expected, ctime_changed):
    marker = tmp_path / f"{chain}.synced"
    value = "00000000-0000-4000-8000-000000000001\n"
    marker.write_text(value)
    st = marker.stat()
    result = {
        "status": "verified",
        "marker": value.strip(),
        "inode": st.st_ino,
        "ctime_ns": st.st_ctime_ns,
    }
    (tmp_path / "results").mkdir()
    (tmp_path / "results" / f"clearnet-{chain}-tor.json").write_text(json.dumps(result))
    marker.write_text(value)
    assert marker.stat().st_ino == st.st_ino
    # The reader executes unchanged, with metadata supplied by a simulated host claim.
    # Pin ctime to the old proof to exercise the collision, independently of the filesystem clock.
    metadata = {
        "st_uid": uid,
        "st_mode": 0o100000 | mode,
        "st_ino": st.st_ino,
        "st_ctime_ns": st.st_ctime_ns + int(ctime_changed),
    }
    wrapper = tmp_path / "host-stat.py"
    wrapper.write_text(
        """
import json, os, sys
from types import SimpleNamespace
metadata = json.loads(sys.argv[1])
sys.argv = sys.argv[2:]
os.fstat = lambda fd: SimpleNamespace(**metadata)
exec(compile(sys.stdin.read(), '<CLI attestation>', 'exec'))
"""
    )
    command = """
source "$1"
state_dir="$2"; fixture="$3"; interpreter="$4"; metadata="$5"; chain="$6"
env_get() { [ "$1" != CONTROL_DIR ] || printf '%s' "$state_dir"; }
clearnet_state_dir() { printf '%s' "$state_dir"; }
python3() { "$interpreter" "$fixture" "$metadata" "$@"; }
clearnet_tor_attested "$chain"
"""
    completed = subprocess.run(  # noqa: S603 -- fixed shell code and isolated test paths
        [
            "/bin/bash",
            "-c",
            command,
            "probe",
            str(ROOT / "lib/pithead/04-status.sh"),
            str(tmp_path),
            str(wrapper),
            sys.executable,
            json.dumps(metadata),
            chain,
        ],
        capture_output=True,
        timeout=5,
        check=False,
    )
    assert completed.returncode == (0 if expected and not ctime_changed else 1), completed.stderr
