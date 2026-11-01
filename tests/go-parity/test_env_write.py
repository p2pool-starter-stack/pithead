import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_env_render as render_fixture

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
ADAPTER = ROOT / "tests/go-parity/env_write_reference.sh"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")
BODY = b"KEY=fixture-private-value\nOTHER=literal$\\value"


class EnvWriteParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache/tmp"
        cache.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        source = (ROOT / "lib/pithead/33-render-env.sh").read_text()
        marker = '        if native_env=$(_render_env_go "$target" 2>/dev/null); then\n'
        start = source.index(marker) + len(marker)
        end = source.index('        else\n            cat <<EOF >"$target"\n', start)
        self.block = self.directory / "block.sh"
        self.block.write_text(
            "publish_case() {\n    (\n        umask 077\n"
            + source[start:end]
            + '\n    )\n    chmod 600 "$target"\n}\n'
        )

    def script(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
        path.chmod(0o755)
        return path

    def invoke(self, arm, name, *, kind="regular", body=BODY, extra=None):
        install = self.directory / f"{name}-{arm}"
        install.mkdir()
        target = install / "target.env"
        original = install / "original.env"
        original.write_bytes(b"previous\n")
        original.chmod(0o640)
        if kind == "regular":
            target.write_bytes(b"previous content longer than new data\n")
            target.chmod(0o640)
        elif kind == "hardlink":
            os.link(original, target)
        elif kind in ("symlink", "dangling"):
            target.symlink_to(original if kind == "symlink" else install / "new.env")
        elif kind == "directory":
            target.mkdir()
        elif kind == "missing-parent":
            target = install / "missing" / "target.env"
        elif kind == "read-only":
            target.write_bytes(b"previous\n")
            target.chmod(0o400)
        elif kind != "new":
            raise ValueError(kind)
        before = target.stat() if target.is_file() else None
        calls, native, capture, argc, status = (
            install / label for label in ("calls", "native", "capture", "argc", "status")
        )
        for observation in (calls, native, capture, argc, status):
            observation.write_bytes(b"")
            observation.chmod(0o600)
        spy = self.script(
            f"{name}-{arm}-spy",
            'printf "%s\\n" "$#" >"$ENV_WRITE_ARGC"\n'
            '/bin/cat >"$ENV_WRITE_CAPTURE"\n'
            "status=0\n"
            '"$ENV_WRITE_REAL_GO" <"$ENV_WRITE_CAPTURE" || status=$?\n'
            'printf "%s\\n" "$status" >"$ENV_WRITE_STATUS"\n'
            'exit "$status"\n',
        )
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            ENV_WRITE_IMPL=arm,
            ENV_WRITE_CALLS=str(calls),
            ENV_WRITE_NATIVE=str(native),
            ENV_WRITE_CAPTURE=str(capture),
            ENV_WRITE_ARGC=str(argc),
            ENV_WRITE_STATUS=str(status),
            ENV_WRITE_REAL_GO=str(GO_BINARY),
            PITHEAD_GO_BINARY=str(spy),
            LC_ALL="C",
        )
        env.update(extra or {})
        if env.pop("ENV_WRITE_USE_MARKER", None) == "1":
            env["PITHEAD_GO_CONFIG_DOCUMENT_BINARY"] = env.pop("PITHEAD_GO_BINARY")
            env["ENV_WRITE_IMPL"] = "bash"
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.block)],
            input=os.fsencode(target) + b"\0" + body + b"\n.\0",
            cwd=install,
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

        def normalize(value):
            return value.replace(os.fsencode(install), b"@ROOT@")

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

        after = target.stat() if target.is_file() else None
        return {
            "result": (result.returncode, normalize(result.stdout), normalize(result.stderr)),
            "calls": calls.read_bytes(),
            "files": tuple(file_state(path) for path in (target, original, install / "new.env")),
            "inode_kept": None
            if before is None or after is None
            else os.path.samestat(before, after),
            "native": native.read_bytes() or None,
            "capture": capture.read_bytes() or None,
            "argc": argc.read_bytes() or None,
            "status": status.read_bytes() or None,
            "expected_frame": os.fsencode(target) + b"\0" + body + b"\x000\x00",
        }

    def compare(self, name, **kwargs):
        baseline = self.invoke("bash", name, **kwargs)
        selected = self.invoke("go", name, **kwargs)
        for key in ("result", "calls", "files", "inode_kept"):
            self.assertEqual(selected[key], baseline[key], (name, key))
        self.assertNotIn(b"fixture-private-value", selected["result"][1] + selected["result"][2])
        return selected

    def assert_native(self, result):
        self.assertEqual(result["native"], b"0\n")
        self.assertEqual(result["status"], b"0\n")
        self.assertEqual(result["argc"], b"0\n")
        self.assertEqual(result["capture"], result["expected_frame"])

    def test_new_and_existing_files_keep_bytes_and_final_mode(self):
        for kind in ("new", "regular"):
            for index, body in enumerate((BODY, b"", b"one\n\n", b"v\xff\r\t", "東京".encode())):
                with self.subTest(kind=kind, index=index):
                    result = self.compare(f"{kind}-{index}", kind=kind, body=body)
                    self.assert_native(result)
                    self.assertEqual(result["result"][0], 0)
                    self.assertEqual(result["calls"], b"chmod\n")
                    self.assertEqual(result["files"][0][1:3], (body + b"\n", 0o600))
                    if kind == "regular":
                        self.assertTrue(result["inode_kept"])

    def test_hardlinks_keep_inode_and_observe_written_bytes(self):
        result = self.compare("hardlink", kind="hardlink")
        self.assert_native(result)
        self.assertTrue(result["inode_kept"])
        self.assertEqual(result["files"][0], result["files"][1])

    def test_parent_umask_does_not_change_publication_contract(self):
        for mask in ("000", "027", "777"):
            with self.subTest(mask=mask):
                result = self.compare(f"mask-{mask}", kind="new", extra={"ENV_WRITE_UMASK": mask})
                self.assert_native(result)
                self.assertEqual(result["files"][0][2], 0o600)

    def test_symlinks_keep_reference_following_and_inode_behavior(self):
        for kind in ("symlink", "dangling"):
            with self.subTest(kind=kind):
                result = self.compare(kind, kind=kind)
                self.assertEqual(result["result"][0], 0)
                self.assertEqual(result["native"], b"125\n")
                self.assertEqual(result["status"], b"125\n")
                self.assertEqual(result["files"][0][0], "link")
                destination = result["files"][1 if kind == "symlink" else 2]
                self.assertEqual(destination[1:3], (BODY + b"\n", 0o600))

    def test_bad_targets_preserve_reference_diagnostics_and_err_traps(self):
        for kind in ("directory", "missing-parent", "read-only"):
            with self.subTest(kind=kind):
                result = self.compare(kind, kind=kind)
                if kind != "read-only" or os.geteuid() != 0:
                    self.assertNotEqual(result["result"][0], 0)
                    self.assertEqual(result["native"], b"125\n")
                    self.assertIn(b"ERR:", result["result"][2])
                else:
                    self.assert_native(result)

    def test_interposed_cat_and_failed_chmod_keep_callbacks(self):
        for shim, expected in (("cat", 0), ("cat-fail", 19), ("chmod-fail", 23)):
            with self.subTest(shim=shim):
                result = self.compare(shim, extra={"ENV_WRITE_SHIM": shim})
                self.assertEqual(result["result"][0], expected)
                if shim == "chmod-fail":
                    self.assert_native(result)
                    self.assertEqual(result["files"][0][2], 0o640)
                else:
                    self.assertEqual(result["native"], b"125\n")
                    self.assertIsNone(result["capture"])

    def test_nonstandard_external_cat_retains_reference(self):
        commands = self.directory / "commands"
        commands.mkdir()
        cat = commands / "cat"
        cat.write_text('#!/bin/sh\nprintf "cat\\n" >>"$ENV_WRITE_CALLS"\nexec /bin/cat "$@"\n')
        cat.chmod(0o755)
        result = self.compare(
            "external-cat", extra={"PATH": str(commands) + os.pathsep + os.environ["PATH"]}
        )
        self.assertEqual(result["result"][0], 0)
        self.assertEqual(result["calls"], b"cat\nchmod\n")
        self.assertEqual(result["native"], b"125\n")
        self.assertIsNone(result["capture"])

    def test_missing_partial_failed_and_hookless_helpers_fall_back(self):
        for name, body in (
            ("failed", "printf 'hidden error\\n' >&2; exit 91\n"),
            ("partial", "printf 0\n"),
            ("trailing", "printf 'extra\\0'\n"),
        ):
            helper = self.script(name, body)
            result = self.compare(name, extra={"PITHEAD_GO_BINARY": str(helper)})
            self.assertEqual(result["native"], b"125\n")
            self.assertEqual(result["result"][0], 0)
        self.compare("missing", extra={"PITHEAD_GO_BINARY": str(self.directory / "missing")})
        self.compare("hookless", extra={"ENV_WRITE_WITHOUT_HOOK": "1"})

    def test_internal_marker_selects_native_writer_with_bash_dispatch(self):
        baseline = self.invoke("bash", "marker")
        selected = self.invoke("go", "marker", extra={"ENV_WRITE_USE_MARKER": "1"})
        for key in ("result", "calls", "files", "inode_kept"):
            self.assertEqual(selected[key], baseline[key], key)
        self.assert_native(selected)

    def test_invalid_protocol_does_not_truncate_or_chmod(self):
        target = self.directory / "protocol.env"
        valid = os.fsencode(target) + b"\0" + BODY + b"\x000\x00"
        for payload, argv in [
            (b"", []),
            (valid[:-1], []),
            (valid + b"extra\0", []),
            (valid[:-2] + b"1\0", []),
            (valid, ["extra"]),
        ]:
            target.write_bytes(b"previous\n")
            target.chmod(0o640)
            before = target.stat()
            result = subprocess.run(  # noqa: S603
                [str(GO_BINARY), *argv],
                input=payload,
                env={**os.environ, "PITHEAD_GO_HELPER": "config-env-write"},
                capture_output=True,
                check=False,
                timeout=15,
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
            self.assertEqual(target.read_bytes(), b"previous\n")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
            self.assertTrue(os.path.samestat(before, target.stat()))

    def test_unchanged_render_fixture_uses_native_publication(self):
        fixture = render_fixture.EnvRenderParityTests(
            "test_bulk_serialization_matches_dotenv_renderer"
        )
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        log = fixture.directory / "write.spy"
        spy = fixture.make_spy(
            "write-spy",
            'if "$ENV_WRITE_REAL_GO" "$@"; then status=0; else status=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "$status" >>"$ENV_WRITE_SPY"\n'
            'exit "$status"\n',
        )
        baseline = fixture.invoke_render("bash", "native-write", fixture.base_config, "0")
        selected = fixture.invoke_render(
            "go",
            "native-write",
            fixture.base_config,
            "0",
            spy,
            {"ENV_WRITE_REAL_GO": str(GO_BINARY), "ENV_WRITE_SPY": str(log)},
        )
        self.assertEqual(selected, baseline)
        calls = log.read_text().splitlines()
        self.assertEqual(calls.count("config-env:0:0"), 1)
        self.assertEqual(calls.count("config-env-write:0:0"), 1)
        self.assertNotIn(fixture.base_config["monero"]["node_password"], log.read_text())


if __name__ == "__main__":
    if not GO_BINARY.is_file():
        raise SystemExit("run make go-build first")
    unittest.main()
