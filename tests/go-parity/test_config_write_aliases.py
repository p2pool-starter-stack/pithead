import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/config_write_aliases_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigWriteAliasTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name, operation, kind):
        path = self.directory / name
        path.mkdir()
        raw = {
            "workers": b'{"xmrig_proxy":{"url":"synthetic-endpoint"}}\n',
            "telegram": b'{"telegram":{"control":{"enabled":true}}}\n',
            "version": b'{"marker":"synthetic"}\n',
        }[operation]
        config = path / "config.json"
        config.write_bytes(raw)
        config.chmod(0o640)
        (path / "VERSION").write_text("2.1.0\n")
        target = path / (
            "config.json.version.alias" if operation == "version" else "config.json.tmp"
        )
        if kind == "hardlink":
            os.link(config, target)
        else:
            target.symlink_to("config.json")
        return path

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            CONFIG_WRITE_ALIASES_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, work, operation, binary=None, extra=None):
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work), operation],
            env=self.environment(implementation, binary, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed.returncode, completed.stdout, completed.stderr, self.snapshot(work)

    def snapshot(self, work):
        result = []
        for name in (
            "config.json",
            "config.json.tmp",
            "config.json.version.alias",
            "config.json.bak-1x",
        ):
            path = work / name
            try:
                metadata = path.lstat()
            except FileNotFoundError:
                result.append(None)
                continue
            if stat.S_ISLNK(metadata.st_mode):
                result.append(("symlink", os.readlink(path), stat.S_IMODE(metadata.st_mode)))
                continue
            raw = path.read_bytes()
            result.append(
                ("file", len(raw), hashlib.sha256(raw).hexdigest(), stat.S_IMODE(metadata.st_mode))
            )
        return tuple(result)

    def spy(self, name, log):
        path = self.directory / name
        path.write_text(
            "#!/bin/sh\n"
            'printf "%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" >>"$CONFIG_ALIAS_LOG"\n'
            'exec "$CONFIG_ALIAS_REAL_GO" "$@"\n'
        )
        path.chmod(0o755)
        return path, {"CONFIG_ALIAS_LOG": str(log), "CONFIG_ALIAS_REAL_GO": str(GO_BINARY)}

    def test_aliases_match_legacy_bytes_status_and_metadata(self):
        for operation in ("workers", "telegram", "version"):
            for kind in ("hardlink", "symlink"):
                with self.subTest(operation=operation, kind=kind):
                    baseline = self.work(f"{operation}-{kind}-bash", operation, kind)
                    selected = self.work(f"{operation}-{kind}-go", operation, kind)
                    expected = self.invoke("bash", baseline, operation)
                    actual = self.invoke("go", selected, operation)
                    self.assertEqual(actual, expected)

    def test_aliases_skip_native_json_writers(self):
        forbidden = {
            "workers": "config-migrations:workers-json",
            "telegram": "config-migrations:telegram-json",
            "version": "config-version:json",
        }
        for operation, writer in forbidden.items():
            with self.subTest(operation=operation):
                baseline = self.work(operation + "-spy-bash", operation, "hardlink")
                selected = self.work(operation + "-spy-go", operation, "hardlink")
                log = self.directory / f"{operation}.log"
                spy, extra = self.spy(operation + "-spy-bin", log)
                expected = self.invoke("bash", baseline, operation)
                actual = self.invoke("go", selected, operation, spy, extra)
                self.assertEqual(actual, expected)
                calls = log.read_text().splitlines()
                self.assertFalse(any(call.startswith(writer) for call in calls))
                self.assertTrue(calls)


if __name__ == "__main__":
    unittest.main(verbosity=2)
