import json
import re
import unittest
from pathlib import Path


class BrowserWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = Path(".github/workflows/browser.yml").read_text()
        cls.steps = {
            match[1]: match[2]
            for match in re.finditer(
                r"^      - name: ([^\n]+)\n(.*?)(?=^      - |\Z)",
                cls.workflow,
                re.MULTILINE | re.DOTALL,
            )
        }

    def test_prebuilt_browsers_match_lock(self):
        image = re.search(
            r"^      image: mcr.microsoft.com/playwright:v([\d.]+)-noble@sha256:([a-f0-9]{64})$",
            self.workflow,
            re.MULTILINE,
        )
        self.assertIsNotNone(image, "use the digest-pinned Playwright browser image")
        lock = json.loads(Path("dashboard/tests/browser/package-lock.json").read_text())
        manifest = json.loads(Path("dashboard/tests/browser/package.json").read_text())
        self.assertEqual(image[1], manifest["devDependencies"]["@playwright/test"])
        for package in ("@playwright/test", "playwright", "playwright-core"):
            self.assertEqual(image[1], lock["packages"]["node_modules/" + package]["version"])
        self.assertNotRegex(self.workflow, r"playwright install|--with-deps|install-deps")
        self.assertIn("      options: --ipc=host\n", self.workflow)

    def test_provisioning_is_bounded_and_required(self):
        self.assertIn("    timeout-minutes: 15\n", self.workflow)
        for name in (
            "Install browser fixture tools",
            "Install locked browser test dependencies",
            "Install pinned Google Chrome for Testing",
        ):
            step = self.steps[name]
            self.assertIn("        timeout-minutes: 2\n", step, name)
            self.assertNotIn("if:", step, name)
        self.assertNotIn("continue-on-error", self.workflow)
        self.assertNotIn("|| true", self.workflow)
        tools = self.steps["Install browser fixture tools"]
        self.assertIn("apt-get install --yes --no-install-recommends make unzip", tools)
        self.assertIn(
            "npm ci --prefix dashboard/tests/browser --ignore-scripts",
            self.steps["Install locked browser test dependencies"],
        )
        chrome = self.steps["Install pinned Google Chrome for Testing"]
        self.assertIn("--connect-timeout 20 --max-time 90", chrome)
        self.assertIn("/141.0.7390.37/linux64/chrome-linux64.zip", chrome)
        self.assertIn("unzip -q", chrome)

    def test_firefox_has_the_container_users_home(self):
        journeys = self.steps["Run cross-browser user journeys and HTTPS backup fixtures"]
        self.assertIn("HOME: /root", journeys)

    def test_all_assertions_remain_required_on_release_prs(self):
        self.assertRegex(
            self.workflow,
            r"pull_request:\n    branches: \[develop, develop-v2\.1\.0\]",
        )
        journeys = self.steps["Run cross-browser user journeys and HTTPS backup fixtures"]
        self.assertIn("run: make test-browser", journeys)
        chrome = self.steps["Assert complete Google Chrome HTTPS backup downloads"]
        self.assertIn("PITHEAD_BACKUP_BROWSER_EXECUTABLE=", chrome)
        self.assertIn("node --test dashboard/tests/browser/backup-download.test.mjs", chrome)
        for step in (journeys, chrome):
            self.assertNotIn("if:", step)
        target = Path("Makefile").read_text().split("test-browser:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("./node_modules/.bin/playwright test", target)
        self.assertIn("node --test dashboard/tests/browser/backup-download.test.mjs", target)
        self.assertIn("python3 scripts/lint/test-browser-workflow.py", Path("Makefile").read_text())


if __name__ == "__main__":
    unittest.main()
