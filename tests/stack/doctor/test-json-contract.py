import json
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PRELUDE = r"""
source "$1/lib/pithead/05-doctor-checks.sh"
source "$1/lib/pithead/06-doctor.sh"
source "$1/lib/pithead/21-doctor-stack-checks.sh"
C_GREEN= C_YELLOW= C_RED= C_RESET= PITHEAD_VERSION=fixture
is_appliance() { [ "$SURFACE" = appliance ]; }
container_is_running() { [[ " $RUNNING_CONTAINERS " == *" $1 "* ]]; }
"""


class DoctorJsonContract(unittest.TestCase):
    def report(self, script, surface="diy", containers=""):
        result = subprocess.run(  # noqa: S603
            ["/bin/bash", "-Eeuo", "pipefail", "-c", PRELUDE + script, "_", str(ROOT)],
            env={**os.environ, "SURFACE": surface, "RUNNING_CONTAINERS": containers},
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        document = json.loads(result.stdout)
        self.assertEqual(result.returncode, document["exit"])
        self.assertEqual(set(document), {"version", "exit", "summary", "checks"})
        return document

    def test_tor_check_keeps_id_across_outcomes_and_surfaces(self):
        for surface in ("diy", "appliance"):
            for containers, status in (("tor", "ok"), ("p2pool", "fail"), ("", "info")):
                with self.subTest(surface=surface, status=status):
                    document = self.report(
                        'doctor() { check_tor_running; [ "$DR_FAIL" -eq 0 ]; }; doctor_json',
                        surface,
                        containers,
                    )
                    self.assertEqual(len(document["checks"]), 1)
                    row = document["checks"][0]
                    self.assertEqual(row["id"], "tor-running")
                    self.assertEqual(row["status"], status)
                    self.assertTrue(row["message"])
                    self.assertEqual(document["exit"], int(status == "fail"))
                    self.assertEqual(
                        document["summary"],
                        {value: int(value == status) for value in ("ok", "warn", "fail", "info")},
                    )

    def test_wording_and_severity_do_not_replace_id(self):
        document = self.report(
            r"""
doctor() {
    dr_ok fixture-check "first wording"
    dr_warn fixture-check "second wording"
    dr_info fixture-check "third wording"
    return 0
}
doctor_json
"""
        )
        self.assertEqual(
            document["checks"],
            [
                {"id": "fixture-check", "status": "ok", "message": "first wording"},
                {"id": "fixture-check", "status": "warn", "message": "second wording"},
                {"id": "fixture-check", "status": "info", "message": "third wording"},
            ],
        )
        self.assertEqual(document["exit"], 0)


if __name__ == "__main__":
    unittest.main()
