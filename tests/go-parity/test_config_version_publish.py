import os
import re
import stat
import subprocess
import unittest

import test_config_version as reference

RAW = b'{"alpha":1,"secret":"fixture-private-value"}\n'


class ConfigVersionPublishParityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = reference.ConfigVersionParityTests(
            "test_stamp_writes_jq_ordered_json_and_secures_mode"
        )
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.addCleanup(setattr, reference, "ADAPTER", reference.ADAPTER)
        reference.ADAPTER = reference.ROOT / "tests/go-parity/config_version_publish_reference.sh"

    def spy(self, name, body=None):
        capture = self.fixture.directory / f"{name}-capture"
        status = self.fixture.directory / f"{name}-status"
        argc = self.fixture.directory / f"{name}-argc"
        for observation in (capture, status, argc):
            observation.write_bytes(b"")
            observation.chmod(0o600)
        script = self.fixture.spy(
            f"{name}-spy",
            'if [ "$#" -ne 0 ]; then exec "$VERSION_PUBLISH_REAL_GO" "$@"; fi\n'
            "original_umask=$(umask)\numask 077\n"
            'printf "%s\\n" "$#" >"$VERSION_PUBLISH_ARGC"\n'
            '/bin/cat >"$VERSION_PUBLISH_CAPTURE"\numask "$original_umask"\n'
            + (
                body
                if body is not None
                else '"$VERSION_PUBLISH_REAL_GO" <"$VERSION_PUBLISH_CAPTURE"; rc=$?\n'
                'printf "%s\\n" "$rc" >"$VERSION_PUBLISH_STATUS"\n'
                'exit "$rc"\n'
            ),
        )
        return script, capture, status, argc

    def invoke(self, arm, name, *, config=RAW, kind="regular", extra=None, body=None):
        work = self.fixture.work(f"{name}-{arm}", config=config)
        target = work / "config.json"
        source = work / "original.json"
        requested_link_group = None
        if kind in ("symlink", "symlink-group"):
            target.rename(source)
            target.symlink_to(source)
            if kind == "symlink-group":
                for group in dict.fromkeys([*os.getgroups(), os.getegid() + 1]):
                    if group == source.stat().st_gid:
                        continue
                    try:
                        os.chown(target, -1, group, follow_symlinks=False)
                    except OSError:
                        continue
                    requested_link_group = group
                    break
        elif kind == "hardlink":
            os.link(target, source)
        elif kind != "regular":
            raise ValueError(kind)
        before = target.lstat()
        spy, capture, status, argc = self.spy(f"{name}-{arm}", body)
        result = self.fixture.invoke(
            arm,
            work,
            "stamp",
            binary=spy,
            extra={
                "CONFIG_VERSION_DRY_RUN": "0",
                "VERSION_PUBLISH_REAL_GO": str(reference.GO_BINARY),
                "VERSION_PUBLISH_CAPTURE": str(capture),
                "VERSION_PUBLISH_STATUS": str(status),
                "VERSION_PUBLISH_ARGC": str(argc),
                "LC_ALL": "C",
                **(extra or {}),
            },
        )
        after = target.lstat()

        def normalize(value):
            value = value.replace(os.fsencode(work), b"@ROOT@")
            value = re.sub(rb"config\.json\.version\.[^/:\n]+", b"config.json.version.TMP", value)
            return re.sub(rb"line \d+", b"line N", value)

        return {
            "result": (result[0], normalize(result[1]), normalize(result[2]), *result[3:]),
            "owner": (after.st_uid, after.st_gid),
            "owner_unchanged": (after.st_uid, after.st_gid) == (before.st_uid, before.st_gid),
            "inode_replaced": before.st_ino != after.st_ino,
            "regular": stat.S_ISREG(after.st_mode),
            "source": source.read_bytes() if source.exists() else None,
            "different_link_group": kind == "symlink-group"
            and before.st_gid != source.stat().st_gid,
            "requested_link_group": requested_link_group,
            "capture": capture.read_bytes() or None,
            "status": status.read_bytes() or None,
            "argc": argc.read_bytes() or None,
            "expected_frame": b"\0".join([config, os.fsencode(target), b"2.1.0", b"0", b""]),
        }

    def compare(self, name, **kwargs):
        expected = self.invoke("bash", name, **kwargs)
        actual = self.invoke("go", name, **kwargs)
        for key in ("result", "owner", "owner_unchanged", "inode_replaced", "regular", "source"):
            self.assertEqual(actual[key], expected[key], (name, key))
        self.assertNotIn(b"fixture-private-value", actual["result"][1] + actual["result"][2])
        return actual

    def test_native_publication_matches_regular_symlink_and_hardlink_transactions(self):
        for kind in ("regular", "symlink", "symlink-group", "hardlink"):
            with self.subTest(kind=kind):
                result = self.compare(kind, kind=kind)
                self.assertEqual((result["result"][0], result["result"][4:]), (0, (0o600, [])))
                self.assertEqual((result["status"], result["argc"]), (b"0\n", b"0\n"))
                self.assertEqual(result["capture"], result["expected_frame"])
                self.assertTrue(
                    result["owner_unchanged"] and result["inode_replaced"] and result["regular"]
                )
                self.assertEqual(result["source"], RAW if kind != "regular" else None)
                if kind == "symlink-group":
                    if result["requested_link_group"] is not None:
                        self.assertTrue(result["different_link_group"])
                        self.assertEqual(result["owner"][1], result["requested_link_group"])
                    else:
                        self.assertFalse(result["different_link_group"])

    def test_interposed_tools_keep_unchanged_bash_transaction(self):
        for tool in ("stat", "mktemp", "chmod", "chown", "mv"):
            with self.subTest(tool=tool):
                result = self.compare(tool, extra={"CONFIG_VERSION_FAIL_TOOL": tool})
                self.assertIsNone(result["capture"])
                self.assertIsNone(result["status"])

    def test_no_write_plans_do_not_invoke_publisher(self):
        for name, config, dry_run in (
            ("equal", b'{ "config_version": "2.1.0", "alpha": 1 }\n', "0"),
            ("dry", RAW, "1"),
            ("newer", b'{"config_version":"9.9.9"}\n', "0"),
        ):
            with self.subTest(name=name):
                result = self.compare(
                    name, config=config, extra={"CONFIG_VERSION_DRY_RUN": dry_run}
                )
                self.assertIsNone(result["capture"])
                self.assertFalse(result["inode_replaced"])
                self.assertEqual(result["result"][3], config)

    def test_caller_umask_keeps_legacy_write_permission_failures(self):
        for mask in ("000", "077", "400", "200", "777"):
            with self.subTest(mask=mask):
                result = self.compare(f"umask-{mask}", extra={"VERSION_PUBLISH_UMASK": mask})
                if int(mask, 8) & 0o200:
                    self.assertIsNone(result["capture"])
                else:
                    self.assertEqual(result["status"], b"0\n")

    def test_unsupported_json_refuses_before_falling_back(self):
        result = self.compare("float", config=b'{"measurement":1.5,"alpha":1}\n')
        self.assertEqual(result["status"], b"125\n")
        self.assertEqual(result["result"][0], 0)
        self.assertEqual(result["result"][4:], (0o600, []))

    def test_malformed_or_failed_publication_helper_uses_original_transaction(self):
        for index, body in enumerate(
            ("exit 125\n", "exit 42\n", "printf garbage\n", "printf '0\\0'\n")
        ):
            with self.subTest(index=index):
                result = self.compare(f"helper-{index}", body=body)
                self.assertEqual(result["result"][0], 0)
                self.assertEqual(result["result"][4:], (0o600, []))

    def test_private_publication_frames_refuse_without_mutating_config(self):
        work = self.fixture.work("protocol", config=RAW)
        target = work / "config.json"
        fields = [RAW, os.fsencode(target), b"2.1.0", b"0", b""]
        good = b"\0".join(fields)
        invalid = (b"", good[:-1], good + b"extra\0", good[:-2] + b"1\0")
        for payload in invalid:
            result = subprocess.run(  # noqa: S603
                [str(reference.GO_BINARY)],
                input=payload,
                env={**os.environ, "PITHEAD_GO_HELPER": "config-version"},
                capture_output=True,
                check=False,
                timeout=15,
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
            self.assertEqual(target.read_bytes(), RAW)
            self.assertEqual(list(work.glob("config.json.version.*")), [])


if __name__ == "__main__":
    if not reference.GO_BINARY.is_file():
        raise SystemExit("run make go-build first")
    unittest.main()
