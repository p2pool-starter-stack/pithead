import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
ADAPTER = ROOT / "tests/go-parity/tari_secret_reference.sh"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")
SECRETS = (b"fixture-view", b"fixture-spend", b"fixture-password")


class TariSecretParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache/tmp"
        cache.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        source = (ROOT / "lib/pithead/33-render-env.sh").read_text()
        start = source.index('    local tari_secret_file="$PWD/data/tari-wallet-secret.env"')
        end = source.index("    # Subshell umask", start)
        self.block = self.directory / "block.sh"
        self.block.write_text("render_secret_case() {\n" + source[start:end] + "}\n")

    def helper_script(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
        path.chmod(0o755)
        return path

    def invoke(self, arm, name, *, kind="regular", secrets=SECRETS, extra=None, gid=None):
        install = self.directory / f"{name}-{arm}"
        install.mkdir()
        data = install / "data"
        data.mkdir(mode=0o700)
        destination = data / "tari-wallet-secret.env"
        original = install / "original"
        original.write_bytes(b"original\n")
        if kind == "regular":
            destination.write_bytes(b"previous\n")
            destination.chmod(0o644)
        elif kind in ("symlink", "dangling"):
            destination.symlink_to(original if kind == "symlink" else install / "missing")
        elif kind == "hardlink":
            os.link(original, destination)
        elif kind == "directory":
            destination.mkdir()
        elif kind == "directory-link":
            directory_target = install / "directory"
            directory_target.mkdir()
            destination.symlink_to(directory_target)
        elif kind != "new":
            raise ValueError(kind)
        values = install / "values"
        target = install / ("dry-run.env" if name == "dry-run" else "target.env")
        fields = [
            os.fsencode(target),
            str(os.geteuid()).encode(),
            str(os.getegid() if gid is None else gid).encode(),
            *secrets,
            b"true"
            if not extra or extra.get("TARI_SECRET_ENABLED", "true") == "true"
            else b"false",
        ]
        values.write_bytes(b"\0".join(fields) + b"\0")
        calls, native, state = (install / name for name in ("calls", "native", "state"))
        calls.write_bytes(b"")
        capture, argc, reply_status = (install / name for name in ("capture", "argc", "status"))
        for observation in (native, state, capture, argc, reply_status):
            observation.write_bytes(b"")
            observation.chmod(0o600)
        spy = self.helper_script(
            f"{name}-{arm}-spy",
            'printf "%s\\n" "$#" >"$TARI_SECRET_ARGC"\n'
            '/bin/cat >"$TARI_SECRET_CAPTURE"\n'
            "status=0\n"
            '"$TARI_SECRET_REAL_GO" <"$TARI_SECRET_CAPTURE" || status=$?\n'
            'printf "%s\\n" "$status" >"$TARI_SECRET_STATUS"\n'
            'exit "$status"\n',
        )
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            TARI_WRITER_IMPL=arm,
            TARI_SECRET_CALLS=str(calls),
            TARI_SECRET_NATIVE=str(native),
            TARI_SECRET_STATE=str(state),
            TARI_SECRET_ARGC=str(argc),
            TARI_SECRET_CAPTURE=str(capture),
            TARI_SECRET_STATUS=str(reply_status),
            TARI_SECRET_REAL_GO=str(GO_BINARY),
            PITHEAD_GO_BINARY=str(spy),
            LC_ALL="C",
        )
        env.update(extra or {})
        if env.pop("TARI_SECRET_USE_MARKER", None) == "1":
            env["PITHEAD_GO_CONFIG_DOCUMENT_BINARY"] = env.pop("PITHEAD_GO_BINARY")
            env["TARI_WRITER_IMPL"] = "bash"
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.block), str(values)],
            cwd=install,
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

        def normalize(value):
            return re.sub(
                rb"\.tari-wallet-secret\.[^/\n]+", b".tari-wallet-secret.TMP", value
            ).replace(os.fsencode(install), b"@ROOT@")

        def file_state(path):
            if path.is_symlink():
                return ("link", normalize(os.fsencode(os.readlink(path))))
            if path.is_file():
                info = path.stat()
                return (
                    "file",
                    path.read_bytes(),
                    stat.S_IMODE(info.st_mode),
                    info.st_uid,
                    info.st_gid,
                )
            return ("directory",) if path.is_dir() else ("missing",)

        files = {
            normalize(os.fsencode(path.relative_to(install))): file_state(path)
            for path in [destination, original, *data.glob(".tari-wallet-secret.*")]
        }
        if destination.is_dir():
            for path in destination.iterdir():
                files[normalize(os.fsencode(path.relative_to(install)))] = file_state(path)
        return {
            "result": (result.returncode, normalize(result.stdout), normalize(result.stderr)),
            "calls": calls.read_bytes(),
            "state": state.read_bytes() if state.exists() else None,
            "files": files,
            "native": native.read_bytes() or None,
            "capture": capture.read_bytes() or None,
            "argc": argc.read_bytes() or None,
            "status": reply_status.read_bytes() or None,
            "expected_frame": b"\0".join([os.fsencode(destination), *fields[1:6], b"0", b""]),
        }

    def compare(self, name, **kwargs):
        baseline = self.invoke("bash", name, **kwargs)
        selected = self.invoke("go", name, **kwargs)
        for key in ("result", "calls", "state", "files"):
            self.assertEqual(selected[key], baseline[key], (name, key))
        for secret in kwargs.get("secrets", SECRETS):
            if secret:
                self.assertNotIn(secret, selected["result"][1] + selected["result"][2])
        return selected

    def assert_native(self, result):
        self.assertEqual(result["result"][0], 0)
        self.assertEqual(result["native"], b"0\n")
        self.assertEqual(result["argc"], b"0\n")
        self.assertEqual(result["status"], b"0\n")
        self.assertEqual(result["capture"], result["expected_frame"])
        self.assertEqual(result["files"][b"data/tari-wallet-secret.env"][2], 0o600)

    def test_native_new_and_existing_files_keep_literal_bytes_and_owner(self):
        for kind in ("new", "regular"):
            for index, secrets in enumerate(
                (SECRETS, (b"", b"", b""), (b"v\n\xff", b"s\r\\$", "東京".encode()))
            ):
                with self.subTest(kind=kind, index=index):
                    result = self.compare(
                        f"{kind}-{index}", kind=kind, secrets=secrets, gid=os.getegid() + 1
                    )
                    self.assert_native(result)

    def test_native_replacement_breaks_links_without_touching_original(self):
        for kind in ("symlink", "dangling", "hardlink"):
            with self.subTest(kind=kind):
                result = self.compare(kind, kind=kind)
                self.assert_native(result)
                self.assertEqual(result["files"][b"original"][1], b"original\n")
                self.assertEqual(result["files"][b"data/tari-wallet-secret.env"][0], "file")

    def test_native_mode_matches_reference_under_callers_umask(self):
        for mask in ("000", "027", "777"):
            with self.subTest(mask=mask):
                self.assert_native(self.compare(f"umask-{mask}", extra={"TARI_SECRET_UMASK": mask}))

    def test_dry_run_skips_secret_and_helper(self):
        result = self.compare("dry-run")
        self.assertEqual(result["result"][0], 0)
        self.assertIsNone(result["native"])
        self.assertIsNone(result["capture"])
        self.assertEqual(result["files"][b"data/tari-wallet-secret.env"][1], b"previous\n")

    def test_interposed_tools_keep_reference_callbacks_and_failure_cleanup(self):
        for shim in (
            "inspect-fail",
            "ownership-fail",
            "ownership-recover",
            "temp-fail",
            "rename-fail",
        ):
            for enabled in ("true", "false"):
                with self.subTest(shim=shim, enabled=enabled):
                    result = self.compare(
                        f"{shim}-{enabled}",
                        extra={"TARI_SECRET_SHIM": shim, "TARI_SECRET_ENABLED": enabled},
                    )
                    self.assertEqual(result["native"], b"125\n")
                    self.assertIsNone(result["capture"])
                    self.assertFalse(
                        any(b".tari-wallet-secret." in name for name in result["files"])
                    )

    def test_missing_partial_failed_or_hookless_helpers_fall_back(self):
        for name, body in (
            ("failed", "printf 'hidden diagnostic\\n' >&2; exit 91\n"),
            ("partial", "printf '0'\n"),
            ("trailing", "printf 'extra\\0'\n"),
        ):
            helper = self.helper_script(name, body)
            result = self.compare(name, extra={"PITHEAD_GO_BINARY": str(helper)})
            self.assertEqual(result["native"], b"125\n")
        self.compare("missing", extra={"PITHEAD_GO_BINARY": str(self.directory / "missing")})
        self.compare("hookless", extra={"TARI_SECRET_WITHOUT_HOOK": "1"})

    def test_directory_destinations_retain_mv_compatibility_fallback(self):
        for kind in ("directory", "directory-link"):
            with self.subTest(kind=kind):
                result = self.compare(kind, kind=kind)
                self.assertEqual(result["result"][0], 0)
                self.assertEqual(result["native"], b"125\n")
                self.assertEqual(result["status"], b"125\n")

    def test_internal_marker_selects_native_writer_with_bash_dispatch(self):
        baseline = self.invoke("bash", "marker")
        selected = self.invoke("go", "marker", extra={"TARI_SECRET_USE_MARKER": "1"})
        for key in ("result", "calls", "state", "files"):
            self.assertEqual(selected[key], baseline[key], key)
        self.assert_native(selected)

    def test_nonstandard_external_tool_retains_reference_failure(self):
        commands = self.directory / "commands"
        commands.mkdir()
        find = commands / "find"
        find.write_text("#!/bin/sh\nexit 1\n")
        find.chmod(0o755)
        result = self.compare(
            "external-find",
            extra={"PATH": str(commands) + os.pathsep + os.environ["PATH"]},
        )
        self.assertEqual(result["result"][0], 1)
        self.assertEqual(result["native"], b"125\n")
        self.assertIsNone(result["capture"])
        self.assertEqual(result["files"][b"data/tari-wallet-secret.env"][1], b"previous\n")

    def test_rejected_protocol_never_changes_existing_file(self):
        destination = self.directory / "protocol.env"
        fields = [
            os.fsencode(destination),
            str(os.geteuid()).encode(),
            str(os.getegid()).encode(),
            *SECRETS,
            b"0",
            b"",
        ]
        valid = b"\0".join(fields)
        invalid = [b"", valid[:-1], valid + b"extra\0", valid[:-2] + b"1\0"]
        for uid in (b"-1", b"01", b"4294967296", str(os.geteuid() + 1).encode()):
            invalid.append(b"\0".join([fields[0], uid, *fields[2:]]))
        for payload, argv in [(value, []) for value in invalid] + [(valid, ["extra"])]:
            destination.write_bytes(b"previous\n")
            result = subprocess.run(  # noqa: S603
                [str(GO_BINARY), *argv],
                input=payload,
                env={**os.environ, "PITHEAD_GO_HELPER": "config-tari-secret"},
                capture_output=True,
                check=False,
                timeout=15,
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
            self.assertEqual(destination.read_bytes(), b"previous\n")
            self.assertEqual(list(self.directory.glob(".tari-wallet-secret.*")), [])


if __name__ == "__main__":
    if not GO_BINARY.is_file():
        raise SystemExit("run make go-build first")
    unittest.main()
