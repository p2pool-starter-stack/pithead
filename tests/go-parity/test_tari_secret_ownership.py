import os
import subprocess
import unittest

import test_tari_secret as reference


class TariSecretOwnershipParityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = reference.TariSecretParityTests(
            "test_native_new_and_existing_files_keep_literal_bytes_and_owner"
        )
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        block = self.fixture.block.read_text()
        self.fixture.block.write_text(
            'sudo() { printf "sudo\\n" >>"$TARI_SECRET_CALLS"; return 1; }\n'
            + block.replace(
                "render_secret_case() {\n",
                "render_secret_case() {\n"
                '    local APP_UID="${OWNERSHIP_UID:-$APP_UID}" '
                'APP_GID="${OWNERSHIP_GID:-$APP_GID}"\n',
            )
        )

    def test_matching_uid_ignores_different_and_sentinel_gid(self):
        for gid in (os.getegid() + 1, 4294967295):
            with self.subTest(gid=gid):
                result = self.fixture.compare(f"matching-{gid}", gid=gid)
                self.fixture.assert_native(result)
                self.assertEqual(result["files"][b"data/tari-wallet-secret.env"][3], os.geteuid())
                self.assertEqual(result["calls"], b"")

    def test_foreign_uid_repairs_or_preserves_file_through_sudo_fallback(self):
        target_uid, target_gid = os.geteuid() + 1, os.getegid() + 1
        result = self.fixture.compare(
            "foreign-owner",
            extra={"OWNERSHIP_UID": str(target_uid), "OWNERSHIP_GID": str(target_gid)},
        )
        self.assertEqual(result["argc"], b"0\n")
        self.assertIsNotNone(result["capture"])
        fields = result["capture"].split(b"\0")
        self.assertEqual(fields[1:3], [str(target_uid).encode(), str(target_gid).encode()])
        secret = result["files"][b"data/tari-wallet-secret.env"]
        if result["result"][0] == 0:
            self.assertEqual(result["result"][0], 0)
            self.assertEqual((result["native"], result["status"]), (b"0\n", b"0\n"))
            self.assertEqual(secret[2:], (0o600, target_uid, target_gid))
            self.assertEqual(result["calls"], b"")
        else:
            self.assertEqual(result["result"][0], 1)
            self.assertEqual((result["native"], result["status"]), (b"125\n", b"125\n"))
            self.assertEqual(secret[1:3], (b"previous\n", 0o644))
            self.assertEqual(result["calls"], b"sudo\n")
        self.assertFalse(any(b".tari-wallet-secret." in path for path in result["files"]))

    def test_shell_selects_owned_helper_with_zero_argv(self):
        observation = self.fixture.directory / "selected-helper"
        spy = self.fixture.helper_script(
            "ownership-spy",
            'printf "%s\\n" "${PITHEAD_GO_HELPER:-}" >"$OWNERSHIP_HELPER"\n'
            'printf "%s\\n" "$#" >"$TARI_SECRET_ARGC"\n'
            '/bin/cat >"$TARI_SECRET_CAPTURE"\n'
            "status=0\n"
            '"$TARI_SECRET_REAL_GO" <"$TARI_SECRET_CAPTURE" || status=$?\n'
            'printf "%s\\n" "$status" >"$TARI_SECRET_STATUS"\n'
            'exit "$status"\n',
        )
        result = self.fixture.compare(
            "owned-helper",
            extra={"PITHEAD_GO_BINARY": str(spy), "OWNERSHIP_HELPER": str(observation)},
        )
        self.fixture.assert_native(result)
        self.assertEqual(observation.read_bytes(), b"config-tari-secret-owned\n")

    def helper(self, fields, *, name="config-tari-secret-owned", args=()):
        return subprocess.run(  # noqa: S603
            [str(reference.GO_BINARY), *args],
            input=b"\0".join(fields),
            env={**os.environ, "PITHEAD_GO_HELPER": name},
            capture_output=True,
            check=False,
            timeout=15,
        )

    def frame(self, destination):
        return [
            os.fsencode(destination),
            str(os.geteuid()).encode(),
            str(os.getegid()).encode(),
            *reference.SECRETS,
            b"0",
            b"",
        ]

    def test_owned_helper_rejects_malformed_frames_before_publication(self):
        destination = self.fixture.directory / "secret"
        valid = self.frame(destination)
        malformed = [[], valid[:-1], [*valid, b"extra"], [*valid[:6], b"1", b""]]
        for index, value in ((1, b"-1"), (1, b"01"), (1, b"4294967296"), (2, b"x")):
            fields = valid.copy()
            fields[index] = value
            malformed.append(fields)
        cases = [(fields, ()) for fields in malformed] + [(valid, ("extra",))]
        for index, (fields, args) in enumerate(cases):
            with self.subTest(index=index):
                destination.write_bytes(b"previous\n")
                result = self.helper(fields, args=args)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
                self.assertEqual(destination.read_bytes(), b"previous\n")
                self.assertEqual(list(self.fixture.directory.glob(".tari-wallet-secret.*")), [])

    def test_owned_helper_rejects_chown_sentinels_without_replacing_file(self):
        destination = self.fixture.directory / "secret"
        for uid, gid in ((4294967295, os.getegid()), (os.geteuid() + 1, 4294967295)):
            with self.subTest(uid=uid, gid=gid):
                fields = self.frame(destination)
                fields[1:3] = [str(uid).encode(), str(gid).encode()]
                destination.write_bytes(b"previous\n")
                result = self.helper(fields)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
                self.assertEqual(destination.read_bytes(), b"previous\n")
                self.assertEqual(list(self.fixture.directory.glob(".tari-wallet-secret.*")), [])

    def test_original_helper_stays_strict_for_foreign_uid(self):
        destination = self.fixture.directory / "secret"
        destination.write_bytes(b"previous\n")
        fields = self.frame(destination)
        fields[1] = str(os.geteuid() + 1).encode()
        result = self.helper(fields, name="config-tari-secret")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
        self.assertEqual(destination.read_bytes(), b"previous\n")
        self.assertEqual(list(self.fixture.directory.glob(".tari-wallet-secret.*")), [])


if __name__ == "__main__":
    if not reference.GO_BINARY.is_file():
        raise SystemExit("run make go-build first")
    unittest.main()
