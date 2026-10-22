import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DOC = (ROOT / "docs/dev/appliance-release.md").read_text()


class ApplianceReleaseDocs(unittest.TestCase):
    def test_verify_commit_survives_sudo(self):
        self.assertIn(
            'sudo env PITHEAD_EXPECT_COMMIT="$(git rev-parse HEAD)" '
            "tests/os/verify-image.sh <image>",
            DOC,
        )
        self.assertNotRegex(DOC, r"PITHEAD_EXPECT_COMMIT=\S+[^\n]* sudo ")

    def test_probe_cleanup_never_prompts(self):
        self.assertRegex(DOC, r"trap '[^\n]*rm -rf \"\$work_dir\"' EXIT")

    def test_packaging_can_write_root_owned_build_directory(self):
        self.assertIn(
            "sudo scripts/release/package-appliance.sh os/rauc/build/system.img "
            "os/rauc/build/update.raucb os/rauc/build/release",
            DOC,
        )

    def test_shipped_fixes_appear_in_generated_release_notes(self):
        notes = subprocess.run(
            ["/bin/bash", "-c", "source scripts/release/bundle.sh; TAG=v2.0.0 changelog_notes"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        unreleased = re.split(r"^## \[", (ROOT / "CHANGELOG.md").read_text(), flags=re.MULTILINE)[1]
        for issue in (3332, 3346, 3358, 3352, 3355):
            with self.subTest(issue=issue):
                self.assertIn(f"(#{issue})", notes)
                self.assertNotIn(f"(#{issue})", unreleased)


if __name__ == "__main__":
    unittest.main()
