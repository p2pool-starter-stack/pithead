# ruff: noqa: S105, S603
import json
import os
import shutil
import subprocess
import unittest

import test_cli
import test_status


class StatusEscapeCasesTest(unittest.TestCase):
    def setUp(self):
        self.status = test_status.StatusParityTest("test_announcements")
        self.status.setUp()

    def tearDown(self):
        self.status.tearDown()

    def invoke(self, implementation, locale, secret, extra=None):
        self.status.model.write_text(json.dumps({}))
        self.status.counter.unlink(missing_ok=True)
        (self.status.install / ".env").write_text(f"PROXY_STRATUM_PASSWORD={secret}\n")
        env = {**self.status.env, "LC_ALL": locale}
        if extra:
            env.update(extra)
        return test_cli.CLIParityTest.invoke(self.status, implementation, "status", env=env)

    def locale_with_charmap(self, utf8):
        locale_program = shutil.which("locale")
        if not locale_program:
            return None
        available = subprocess.run(
            [locale_program, "-a"], capture_output=True, check=False, text=True
        )
        for locale in available.stdout.splitlines():
            if locale in {"C", "POSIX"}:
                continue
            probe = subprocess.run(
                [locale_program, "charmap"],
                env={**os.environ, "LC_ALL": locale},
                capture_output=True,
                check=False,
                text=True,
            )
            charmap = probe.stdout.strip().lower().replace("-", "").replace("_", "")
            if probe.returncode == 0 and (charmap == "utf8") == utf8:
                return locale
        return None

    def test_escape_bytes_match_bash(self):
        utf8_locale = self.locale_with_charmap(True)
        if not utf8_locale:
            self.skipTest("no UTF-8 locale available")
        secret = (
            r"pre\uD800mid\U00110000wide\U003FFFFFfive"
            r"\U7FFFFFFFsix\U80000000drop\xFFraw\0777oct"
        )
        expected = {
            utf8_locale: (
                b"pre\xed\xa0\x80mid\xf4\x90\x80\x80wide"
                b"\xf8\x8f\xbf\xbf\xbffive\xfd\xbf\xbf\xbf\xbf\xbfsix"
                b"drop\xffraw\xffoct"
            ),
            "C": (
                rb"pre\uD800mid\U00110000wide\U003FFFFFfive"
                rb"\U7FFFFFFFsixdrop" + b"\xffraw\xffoct"
            ),
        }
        for locale, rendered in expected.items():
            with self.subTest(locale=locale):
                baseline = self.invoke("bash", locale, secret)
                native = self.invoke("go", locale, secret)
                self.assertEqual(
                    (native.returncode, native.stdout, native.stderr),
                    (baseline.returncode, baseline.stdout, baseline.stderr),
                )
                self.assertEqual(native.returncode, 0)
                self.assertIn(rendered, native.stdout)

    def test_escape_bytes_stay_native(self):
        utf8_locale = self.locale_with_charmap(True)
        if not utf8_locale:
            self.skipTest("no UTF-8 locale available")
        secret = r"fixture\uD800\U00110000\U80000000tail"
        baseline = self.invoke("bash", utf8_locale, secret)
        sentinel = self.status.install / "fallback-called"
        fake = self.status.bin / "bash"
        fake.write_text('#!/bin/sh\nprintf called >"$STATUS_ESCAPE_SENTINEL"\nexit 91\n')
        fake.chmod(0o755)
        env = self.status.child_environment(
            "go",
            {
                **self.status.env,
                "LC_ALL": utf8_locale,
                "STATUS_ESCAPE_SENTINEL": str(sentinel),
            },
        )
        native = subprocess.run(
            [test_cli.REAL_BASH, str(self.status.cli), "status"],
            cwd=self.status.install,
            env=env,
            capture_output=True,
            check=False,
            timeout=30,
        )
        self.assertEqual(
            (native.returncode, native.stdout, native.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertFalse(sentinel.exists())

    def test_non_utf8_locale_uses_reference(self):
        locale = self.locale_with_charmap(False)
        if not locale:
            self.skipTest("no non-UTF-8 locale available")
        secret = r"fixture\u00E9\uD800\U00110000tail"
        baseline = self.invoke("bash", locale, secret)
        sentinel = self.status.install / "fallback-called"
        fake = self.status.bin / "bash"
        fake.write_text(
            "#!/bin/sh\n"
            'printf called >"$STATUS_ESCAPE_SENTINEL"\n'
            f'exec "{test_cli.REAL_BASH}" "$@"\n'
        )
        fake.chmod(0o755)
        native = self.invoke("go", locale, secret, {"STATUS_ESCAPE_SENTINEL": str(sentinel)})
        self.assertEqual(
            (native.returncode, native.stdout, native.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertTrue(sentinel.exists())

    def test_invalid_locale_keeps_single_reference_startup(self):
        secret = r"fixture\u00E9\uD800\U00110000tail"
        baseline = self.invoke("bash", "pithead_INVALID", secret)
        sentinel = self.status.install / "native-called"
        fake = self.status.bin / "unexpected-go"
        fake.write_text('#!/bin/sh\nprintf called >"$STATUS_ESCAPE_SENTINEL"\nexit 91\n')
        fake.chmod(0o755)
        native = self.invoke(
            "go",
            "pithead_INVALID",
            secret,
            {"PITHEAD_GO_BINARY": str(fake), "STATUS_ESCAPE_SENTINEL": str(sentinel)},
        )
        self.assertEqual(
            (native.returncode, native.stdout, native.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertFalse(sentinel.exists())


if __name__ == "__main__":
    unittest.main()
