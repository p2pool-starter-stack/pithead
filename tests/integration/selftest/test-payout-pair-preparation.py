"""Exercise live fixture preparation without Docker or wallet-selection substitutes."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DOCKER = """#!/usr/bin/env python3
import json, os, sys, shutil
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['DOCKER_TRACE'], 'a') as out:
    out.write(json.dumps(args) + '\\n')
if args[0] == 'compose' and 'config' in args:
    if os.environ.get('REFUSE_MODEL') == '1' or '--profile' not in args or args[args.index('--profile') + 1] != '*':
        print('service tari-wallet depends on undefined service tari', file=sys.stderr)
        sys.exit(1)
    print(json.dumps({'services': {'tari-wallet': {'image': 'fixture-wallet:test'}}}))
if args[0] == 'run':
    source, target = args[args.index('-v') + 1].split(':')
    path = Path(source).resolve()
    assert target == '/fixture' and path.is_relative_to(Path(os.environ['DOCKER_TRACE']).parent)
    for child in path.iterdir():
        if child.is_dir() and not child.is_symlink(): shutil.rmtree(child)
        else: child.unlink()
if args[0] == 'pull' and args[1] != 'fixture-wallet:test':
    print('invalid reference format', file=sys.stderr)
    sys.exit(1)
"""


class PreparationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in (
            "pithead",
            "config.reference.json",
            "config.core-keys.json",
            "VERSION",
            ".env",
            "config.json",
        ):
            (self.root / name).write_text("{}\n")
        (self.root / "build").mkdir()
        fixtures = self.root / "tests/integration/fixtures"
        fixtures.mkdir(parents=True)
        shutil.copyfile(
            ROOT / "tests/integration/fixtures/payout-pairs.sh", fixtures / "payout-pairs.sh"
        )
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, content in (("docker", DOCKER), ("make", '#!/bin/sh\nprintf "1\\n"\n')):
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o700)
        self.trace = self.root / "docker.trace"
        # Execute the shipped preparation, stopping before node inputs or service creation.
        source = (ROOT / "tests/integration/payout-pairs/run.sh").read_text()
        self.script = source.split("# Endpoint values stay private;")[0]

    def run_preparation(self, refuse=False):
        result = subprocess.run(  # noqa: S603 — fixed repository script, test-owned paths
            [shutil.which("bash"), "-c", self.script],
            cwd=self.root,
            env={
                **os.environ,
                "TMPDIR": str(self.root),
                "PATH": f"{self.bin}:{os.environ['PATH']}",
                "DOCKER_TRACE": str(self.trace),
                "REFUSE_MODEL": "1" if refuse else "0",
            },
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        return result, calls

    def test_image_lookup_includes_profile_dependencies_before_pull(self):
        result, calls = self.run_preparation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["pull", "fixture-wallet:test"], calls)

    def test_toolbox_account_matches_caller_for_owner_only_files(self):
        result, calls = self.run_preparation()
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [call for call in calls if call[0] == "build" and call[-1] == "tests/runner"]
        self.assertEqual(len(builds), 1)
        self.assertIn(f"PITHEAD_UID={os.getuid()}", builds[0])
        self.assertIn(f"PITHEAD_GID={os.getgid()}", builds[0])

    def test_failed_model_lookup_never_attempts_image_pull(self):
        result, calls = self.run_preparation(refuse=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("depends on undefined service", result.stderr)
        self.assertFalse(any(call[0] == "pull" for call in calls))


if __name__ == "__main__":
    unittest.main()
