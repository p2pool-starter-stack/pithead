import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class DonationDestinationTest(unittest.TestCase):
    def assert_primary(self, address):
        result = subprocess.run(  # noqa: S603
            [
                "/bin/bash",
                "-c",
                'source "$1"; monero_address_type "$2"',
                "_",
                str(ROOT / "lib/pithead/25-address-types.sh"),
                address,
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
        self.assertEqual(result.stdout.strip(), "primary")

    def primary_fixture(self):
        fixture = re.search(
            r'^VALID_PRIMARY="([^"]+)"$', (ROOT / "tests/stack/lib.sh").read_text(), re.M
        )
        self.assertIsNotNone(fixture)
        return fixture[1]

    def test_fixture_checksum(self):
        address = self.primary_fixture()
        self.assert_primary(address)
        with self.assertRaises(AssertionError):
            self.assert_primary(address[:-1] + ("1" if address[-1] != "1" else "2"))

    def test_shipped_checksum(self):
        address = json.loads(
            (ROOT / "dashboard/mining_dashboard/config/donation.json").read_text()
        )["project_address"]
        if not address:
            self.skipTest("shipped project_address skipped: empty")
        self.assert_primary(address)

    def test_only_loader_reads_destination(self):
        result = subprocess.run(  # noqa: S603
            [
                "/usr/bin/git",
                "grep",
                "-l",
                "-F",
                "donation.json",
                "--",
                ".",
                ":(exclude)tests/**",
                ":(exclude)**/tests/**",
                ":(exclude)docs/**",
                ":(exclude)*.md",
                ":(exclude)**/*.md",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
        self.assertEqual(
            result.stdout.splitlines(),
            ["dashboard/mining_dashboard/config/donation_destination.py"],
        )

    def assert_no_drift(self, address, documents):
        for name, text in documents.items():
            addresses = re.findall(
                r"\b[48][1-9A-HJ-NP-Za-km-z]{94}(?:[1-9A-HJ-NP-Za-km-z]{11})?\b", text
            )
            self.assertTrue(
                all(found == address for found in addresses), f"project_address drift in {name}"
            )

    def test_shipped_documentation_drift(self):
        address = json.loads(
            (ROOT / "dashboard/mining_dashboard/config/donation.json").read_text()
        )["project_address"]
        if not address:
            self.skipTest("project_address drift skipped: empty; no documentation checked")
        self.assert_no_drift(
            address,
            {
                name: (ROOT / name).read_text()
                for name in ("README.md", "docs/donation.md", "docs/privacy.md")
            },
        )

    def test_documentation_drift_detects_every_occurrence(self):
        address = self.primary_fixture()
        for name in ("README.md", "docs/donation.md", "docs/privacy.md"):
            with self.subTest(document=name):
                self.assert_no_drift(address, {name: f"Address: {address}\nRepeated: {address}"})
                with self.assertRaisesRegex(AssertionError, "project_address drift"):
                    self.assert_no_drift(
                        address, {name: f"Address: {address}\nOther: {'4' + 'a' * 94}"}
                    )


if __name__ == "__main__":
    unittest.main()
