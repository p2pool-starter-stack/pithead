import os
import re
import stat
import subprocess
import unittest

import test_config_persistence as reference

RAW = b'{"first":1,"monero":{"wallet_address":"fixture-wallet"},"last":true}\n'
USER, PASSWORD = ("fixture-user", "fixture-password")


class CredentialsPublishParityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = reference.ConfigPersistenceParityTests(
            "test_credentials_preserve_order_and_arbitrary_strings"
        )
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.addCleanup(setattr, reference, "ADAPTER", reference.ADAPTER)
        reference.ADAPTER = reference.ROOT / "tests/go-parity/credentials_publish_reference.sh"

    def invoke(self, arm, name, *, raw=RAW, kind="regular", extra=None, body=None):
        work = self.fixture.work(f"{name}-{arm}", raw)
        target = work / "config.json"
        original = work / "original.json"
        stage = work / "config.json.tmp"
        if kind == "symlink":
            target.rename(original)
            target.symlink_to(original)
        elif kind == "hardlink":
            os.link(target, original)
        elif kind == "existing-stage":
            stage.write_bytes(b"old fixture content")
            stage.chmod(0o644)
        elif kind == "stage-symlink":
            original.write_bytes(b"old fixture content")
            stage.symlink_to(original)
        elif kind != "regular":
            raise ValueError(kind)
        before = target.lstat()
        capture, status, argc = (
            self.fixture.directory / f"{name}-{arm}-{key}" for key in ("capture", "status", "argc")
        )
        for observer in (capture, status, argc):
            observer.write_bytes(b"")
            observer.chmod(0o600)
        spy = self.fixture.spy(
            f"{name}-{arm}-spy",
            'if [ "$#" -ne 2 ] || [ "$1" != credentials ] || [ "$2" != publish ]; then\n'
            '    exec "$CREDENTIALS_PUBLISH_REAL_GO" "$@"\nfi\n'
            "original_umask=$(umask)\numask 077\n"
            'printf "%s\\n" "$#:$1:$2" >"$CREDENTIALS_PUBLISH_ARGC"\n'
            '/bin/cat >"$CREDENTIALS_PUBLISH_CAPTURE"\numask "$original_umask"\n'
            + (
                body
                if body is not None
                else '"$CREDENTIALS_PUBLISH_REAL_GO" "$@" <"$CREDENTIALS_PUBLISH_CAPTURE"; rc=$?\n'
                'if [ "$rc" -eq 0 ] && [ "${CREDENTIALS_PUBLISH_AFTER_FAILURE:-0}" = 1 ]; then\n'
                "    /bin/rm -f -- config.json\nfi\n"
                'printf "%s\\n" "$rc" >"$CREDENTIALS_PUBLISH_STATUS"\nexit "$rc"\n'
            ),
        )
        result = self.fixture.invoke(
            arm,
            work,
            "credentials",
            USER,
            PASSWORD,
            binary=spy,
            extra={
                "CREDENTIALS_PUBLISH_REAL_GO": str(reference.GO_BINARY),
                "CREDENTIALS_PUBLISH_CAPTURE": str(capture),
                "CREDENTIALS_PUBLISH_STATUS": str(status),
                "CREDENTIALS_PUBLISH_ARGC": str(argc),
                "LC_ALL": "C",
                **(extra or {}),
            },
        )
        after = target.lstat() if target.exists() or target.is_symlink() else None

        def normalize(value):
            return re.sub(rb"line \d+", b"line N", value.replace(os.fsencode(work), b"@ROOT@"))

        return {
            "result": (result[0], normalize(result[1]), normalize(result[2]), result[3]),
            "capture": capture.read_bytes() or None,
            "status": status.read_bytes() or None,
            "argc": argc.read_bytes() or None,
            "replaced": after is not None and before.st_ino != after.st_ino,
            "regular": after is not None and stat.S_ISREG(after.st_mode),
            "owner": (after.st_uid, after.st_gid) if after is not None else None,
            "original": original.read_bytes() if original.exists() else None,
            "frame": b"\0".join([raw, b"config.json", USER.encode(), PASSWORD.encode(), b"0", b""]),
        }

    def compare(self, name, **kwargs):
        expected = self.invoke("bash", name, **kwargs)
        actual = self.invoke("go", name, **kwargs)
        for key in ("result", "replaced", "regular", "owner", "original"):
            self.assertEqual(actual[key], expected[key], (name, key))
        self.assertNotIn(PASSWORD.encode(), actual["result"][1] + actual["result"][2])
        return actual

    def test_native_publication_preserves_regular_and_link_contracts(self):
        for kind in ("regular", "symlink", "hardlink"):
            with self.subTest(kind=kind):
                result = self.compare(kind, kind=kind)
                self.assertEqual(result["result"][0], 0)
                self.assertEqual(result["status"], b"0\n")
                self.assertEqual(result["argc"], b"2:credentials:publish\n")
                self.assertEqual(result["capture"], result["frame"])
                self.assertTrue(result["replaced"] and result["regular"])
                self.assertEqual(result["result"][3][0][1], 0o600)
                self.assertIsNone(result["result"][3][1])
                self.assertEqual(result["original"], None if kind == "regular" else RAW)

    def test_existing_stages_keep_legacy_behavior(self):
        for kind in ("existing-stage", "stage-symlink"):
            with self.subTest(kind=kind):
                result = self.compare(kind, kind=kind)
                self.assertIsNone(result["capture"])
                self.assertEqual(result["result"][0], 0)

    def test_dry_run_preserves_bytes_and_skips_native_publication(self):
        result = self.compare("dry-run", extra={"CONFIG_PERSISTENCE_DRY_RUN": "1"})
        self.assertEqual(result["result"][3][0], (RAW, 0o640))
        self.assertFalse(result["replaced"])
        self.assertIsNone(result["capture"])

    def test_caller_umasks_match_bash_subshell_security(self):
        for mask in ("000", "077", "200", "777"):
            with self.subTest(mask=mask):
                result = self.compare(f"umask-{mask}", extra={"CREDENTIALS_PUBLISH_UMASK": mask})
                self.assertEqual(result["status"], b"0\n")
                self.assertEqual(result["result"][3][0][1], 0o600)

    def test_tool_failures_and_err_traps_keep_legacy_path(self):
        for tool in ("mv", "chmod", "cat"):
            for trap in ("0", "1"):
                with self.subTest(tool=tool, trap=trap):
                    result = self.compare(
                        f"tool-{tool}-{trap}",
                        extra={
                            "CONFIG_PERSISTENCE_FAIL_TOOL": tool,
                            "CONFIG_PERSISTENCE_ERR_TRAP": trap,
                        },
                    )
                    self.assertIsNone(result["capture"])

    def test_post_publication_chmod_failure_keeps_status_and_err_context(self):
        for context in ("normal", "conditional"):
            with self.subTest(context=context):
                result = self.compare(
                    f"after-{context}",
                    extra={
                        "CREDENTIALS_PUBLISH_AFTER_FAILURE": "1",
                        "CREDENTIALS_PUBLISH_CONTEXT": context,
                        "CONFIG_PERSISTENCE_ERR_TRAP": "1",
                    },
                )
                self.assertEqual(result["status"], b"0\n")
                self.assertIsNone(result["result"][3][0])
                if context == "normal":
                    self.assertEqual(result["result"][0:2], (1, b"err:1\n"))
                else:
                    self.assertEqual(result["result"][0:2], (0, b"result:1\n"))

    def test_unsupported_json_and_malformed_helpers_fall_back(self):
        result = self.compare("float", raw=b'{"measurement":1.5}\n')
        self.assertEqual(result["status"], b"125\n")
        for index, body in enumerate(
            ("exit 125\n", "exit 42\n", "printf garbage\n", "printf '0\\0'\n")
        ):
            with self.subTest(index=index):
                result = self.compare(f"helper-{index}", body=body)
                self.assertEqual(result["result"][0], 0)

    def test_private_publication_protocol_refuses_before_writing(self):
        work = self.fixture.work("protocol", RAW)
        target = work / "config.json"
        good = b"\0".join([RAW, os.fsencode(target), USER.encode(), PASSWORD.encode(), b"0", b""])
        for payload, args in [
            (p, ["credentials", "publish"])
            for p in (b"", good[:-1], good + b"x\0", good[:-2] + b"1\0")
        ] + [(good, ["credentials", "publish", "extra"])]:
            result = subprocess.run(  # noqa: S603
                [str(reference.GO_BINARY), *args],
                input=payload,
                env={**os.environ, "PITHEAD_GO_HELPER": "config-persistence"},
                capture_output=True,
                check=False,
                timeout=15,
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
            self.assertEqual(target.read_bytes(), RAW)
            self.assertFalse((work / "config.json.tmp").exists())


if __name__ == "__main__":
    if not reference.GO_BINARY.is_file():
        raise SystemExit("run make go-build first")
    unittest.main()
