import os
import subprocess

BASH = "/bin/bash"


class PreviewContractTests:
    def test_source_only_and_non_c_locale_use_bash(self):
        self.compare_describe(
            "source-only", b"MONERO_PRUNE", b"false", b"true", extra={"PREVIEW_SOURCE_ONLY": "1"}
        )
        self.compare_env("source-only-env", b"A=1\n", b"A=2\n", extra={"PREVIEW_SOURCE_ONLY": "1"})
        locale = next(
            (item for item in ("C.UTF-8", "en_US.UTF-8") if self.locale_available(item)), None
        )
        if locale is None:
            self.skipTest("no non-C locale is available")
        self.compare_env("locale-fallback", b"B=1\nA=2\n", b"B=2\nA=2\n", locale=locale)

    def test_helper_opcode_and_frames_are_selected(self):
        spy = self.executable(
            "spy",
            'printf "%s:%s\\n" "$PITHEAD_GO_HELPER" "$1" >helper.log\n'
            "command cat >helper.stdin\n"
            'case "$1" in describe) printf "SPY\\tselected\\0" ;; '
            'env-diff) printf "SPY_KEY\\n\\0" ;; *) exit 64 ;; esac\n',
        )
        work = self.work("spy-describe")
        frame = b"MONERO_PRUNE\0false\0true\0\0"
        result = self.invoke("go", work, "describe", frame=frame, binary=spy)
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr), (0, b"SPY\tselected", b"")
        )
        self.assertEqual((work / "helper.log").read_bytes(), b"config-preview:describe\n")
        self.assertEqual((work / "helper.stdin").read_bytes(), frame + b"0\0")
        work = self.work("spy-env")
        (work / "old.env").write_bytes(b"A=1\n")
        (work / "new.env").write_bytes(b"A=2\n")
        result = self.invoke("go", work, "env-diff", binary=spy)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"SPY_KEY\n", b""))
        self.assertEqual((work / "helper.log").read_bytes(), b"config-preview:env-diff\n")
        expected = b"A=1\n" + b"\0" + b"0\0A=2\n" + b"\0" + b"0\0"
        self.assertEqual((work / "helper.stdin").read_bytes(), expected)
        work = self.work("spy-env-empty")
        (work / "old.env").write_bytes(b"A=1\n")
        (work / "new.env").write_bytes(b"A=1\n")
        empty = self.executable(
            "spy-empty",
            'printf "%s:%s\\n" "$PITHEAD_GO_HELPER" "$1" >helper.log\n'
            'command cat >helper.stdin\nprintf "\\0"\n',
        )
        result = self.invoke("go", work, "env-diff", binary=empty)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        self.assertEqual((work / "helper.log").read_bytes(), b"config-preview:env-diff\n")

    def test_refused_malformed_partial_and_failed_helpers_fall_back(self):
        bodies = {
            "refused": "command cat >/dev/null\nexit 125\n",
            "malformed": "command cat >/dev/null\nprintf broken\n",
            "partial": 'command cat >/dev/null\nprintf "INFO\\tpartial\\0trailing"\n',
            "failed": "command cat >/dev/null\nexit 7\n",
        }
        for name, body in bodies.items():
            with self.subTest(name=name):
                binary = self.executable("helper-" + name, body)
                self.compare_describe(
                    "fallback-" + name,
                    b"MONERO_PRUNE",
                    b"false",
                    b"true",
                    binary=binary,
                )
                self.compare_env("env-fallback-" + name, b"A=1\n", b"A=2\n", binary=binary)
        missing = self.directory / "missing-helper"
        self.compare_describe(
            "fallback-missing", b"MONERO_PRUNE", b"false", b"true", binary=missing
        )

    def test_helper_rejects_unsupported_and_bad_frames(self):
        unsupported = [
            (b"TARI_MODE", b"off", b"local"),
            (b"PROXY_STRATUM_PASSWORD", b"", b"secret"),
            (b"TOR_AUTO_HEAL", b"true", b"false"),
            (b"XVB_TOR_ENABLED", b"true", b"false"),
            (b"P2POOL_CLEARNET", b"false", b"true"),
        ]
        for key, old, new in unsupported:
            with self.subTest(key=key):
                self.assertEqual(
                    self.helper("describe", (key, old, new, b"", b"0")).returncode, 125
                )
        malformed = (
            ("describe", (b"MONERO_PRUNE", b"false")),
            ("describe", (b"MONERO_PRUNE", b"false", b"true", b"", b"1")),
            ("describe", (b"MONERO_PRUNE", b"false", b"true", b"", b"0", b"extra")),
            ("env-diff", (b"A=1\n", b"0", b"A=2\n")),
            ("env-diff", (b"A=1\n", b"1", b"A=2\n", b"0")),
            ("env-diff", (b"A=1\n", b"0", b"A=2\n", b"0", b"extra")),
        )
        for operation, fields in malformed:
            with self.subTest(operation=operation, fields=fields):
                self.assertEqual(self.helper(operation, fields).returncode, 125)

    def test_env_diff_read_failure_falls_back(self):
        results = []
        for failed in ("old", "new"):
            results.clear()
            for implementation in ("bash", "go"):
                work = self.work("read-failure-" + failed + "-" + implementation)
                (work / "old.env").write_bytes(b"A=1\n")
                (work / "new.env").write_bytes(b"A=2\n")
                (work / (failed + ".env")).unlink()
                (work / (failed + ".env")).mkdir()
                results.append(self.invoke(implementation, work, "env-diff"))
            expected, actual = results
            self.assertEqual(
                (actual.returncode, actual.stdout, actual.stderr),
                (expected.returncode, expected.stdout, expected.stderr),
            )

    def test_env_diff_requires_byte_collation_and_character_locale(self):
        locale = next(
            (item for item in ("C.UTF-8", "en_US.UTF-8") if self.locale_available(item)), None
        )
        if locale is None:
            self.skipTest("no non-C locale is available")
        spy = self.executable("locale-spy", 'command cat >/dev/null\nprintf "WRONG\\n\\0"\n')
        extra = {"LC_ALL": "", "LC_COLLATE": "C", "LC_CTYPE": locale, "LANG": "C"}
        self.compare_env("ctype-fallback", b"A=1\n", b"A=2\n", binary=spy, extra=extra, locale="")

    def locale_available(self, locale):
        return (
            subprocess.run(  # noqa: S603
                [BASH, "-c", ":"],
                env={**os.environ, "LC_ALL": locale},
                capture_output=True,
                check=False,
            ).returncode
            == 0
        )
