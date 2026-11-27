"""CLI status rejects replayed dashboard markers even when inode and ctime collide."""

import itertools
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class ClearnetAttestationTest(unittest.TestCase):
    def test_host_claim_and_ctime(self):
        permissions = [(0, 0o644, True), (1000, 0o644, False), (0, 0o664, False), (0, 0o646, False)]
        for chain, (uid, mode, expected), ctime_changed in itertools.product(
            ("monero", "tari"), permissions, (False, True)
        ):
            with self.subTest(chain=chain, uid=uid, mode=mode, ctime_changed=ctime_changed):
                with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
                    self.check_case(Path(directory), chain, uid, mode, expected, ctime_changed)

    def check_case(self, tmp_path, chain, uid, mode, expected, ctime_changed):
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
        self.assertEqual(marker.stat().st_ino, st.st_ino)
        # Pin ctime to the old proof so the collision does not depend on the filesystem clock.
        metadata = {
            "st_uid": uid,
            "st_mode": 0o100000 | mode,
            "st_ino": st.st_ino,
            "st_ctime_ns": st.st_ctime_ns + int(ctime_changed),
        }
        wrapper = tmp_path / "host-stat.py"
        wrapper.write_text(
            textwrap.dedent("""
    import json, os, sys
    from types import SimpleNamespace
    metadata = json.loads(sys.argv[1])
    sys.argv = sys.argv[2:]
    os.fstat = lambda fd: SimpleNamespace(**metadata)
    exec(compile(sys.stdin.read(), '<CLI attestation>', 'exec'))
    """)
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
        self.assertEqual(
            completed.returncode, 0 if expected and not ctime_changed else 1, completed.stderr
        )


if __name__ == "__main__":
    unittest.main()
