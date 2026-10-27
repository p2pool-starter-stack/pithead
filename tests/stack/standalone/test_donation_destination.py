import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class DonationChecksumTest(unittest.TestCase):
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

    def test_fixture_checksum(self):
        fixture = re.search(
            r'^VALID_PRIMARY="([^"]+)"$', (ROOT / "tests/stack/lib.sh").read_text(), re.M
        )
        self.assertIsNotNone(fixture)
        self.assert_primary(fixture[1])
        with self.assertRaises(AssertionError):
            self.assert_primary(fixture[1][:-1] + ("1" if fixture[1][-1] != "1" else "2"))

    def test_shipped_checksum(self):
        address = json.loads(
            (ROOT / "dashboard/mining_dashboard/config/donation.json").read_text()
        )["project_address"]
        if not address:
            self.skipTest("shipped project_address skipped: empty")
        self.assert_primary(address)


if __name__ == "__main__":
    unittest.main()
