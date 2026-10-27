import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / "tests/stack/standalone/compose-project-render.sh"
BASH = shutil.which("bash")


class ComposeProjectRenderTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        folder = Path(self.scratch.name)
        self.fixture = folder / "representative env"
        self.fixture.touch()
        docker = folder / "docker"
        self.fail_project = folder / "fail-project"
        expected = [
            "compose",
            "--env-file",
            str(self.fixture),
            "-f",
            str(ROOT / "docker-compose.yml"),
            "--profile",
            "*",
            "config",
            "--format",
            "json",
        ]
        docker.write_text(
            f"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
assert sys.argv[1:] == {expected!r}
assert all(k == "COMPOSE_PROJECT_NAME" for k in os.environ if k.startswith("COMPOSE_"))
assert "TELEGRAM_BOT_TOKEN" not in os.environ
assert "MONERO_VIEW_KEY" not in os.environ
project = os.environ.get("COMPOSE_PROJECT_NAME", "pithead")
fail = Path({str(self.fail_project)!r})
if fail.exists() and fail.read_text() == project:
    sys.exit(9)
print(json.dumps(dict(name=project, source={str(ROOT)!r})))
"""
        )
        docker.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(folder) + os.pathsep + os.environ["PATH"],
            "TELEGRAM_BOT_TOKEN": "inherited-secret-sentinel",
            "MONERO_VIEW_KEY": "inherited-view-sentinel",
            "COMPOSE_PROJECT_NAME": "inherited",
            "COMPOSE_PROFILES": "unrelated",
            "COMPOSE_FILE": "unrelated.yml",
        }

    def run_helper(self):
        return subprocess.run(  # noqa: S603
            [BASH, str(HELPER), str(self.fixture)],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_profiles_environment_and_redacted_retention(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            [
                {"name": "pithead", "source": "<workspace>"},
                {"name": "pithead-gate", "source": "<workspace>"},
            ],
        )

    def test_failed_render_never_emits_partial_evidence(self):
        for project in ("pithead", "pithead-gate"):
            with self.subTest(project=project):
                self.fail_project.write_text(project)
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
