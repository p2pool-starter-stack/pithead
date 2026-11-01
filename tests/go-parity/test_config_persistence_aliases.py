import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/config_persistence_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigPersistenceAliasTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name):
        path = self.directory / name
        path.mkdir()
        return path

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            CONFIG_PERSISTENCE_PARITY_IMPL=implementation,
            CONFIG_PERSISTENCE_CALL_LOG="calls",
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, work, operation, *args, binary=None, extra=None):
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work), operation, *args],
            env=self.environment(implementation, binary, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed.returncode, completed.stdout, completed.stderr, self.snapshot(work)

    def snapshot(self, work):
        result = []
        for name in ("config.json", "config.json.tmp", "alt.json", "defaults.tmp"):
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
            'printf "%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" >>"$PERSISTENCE_ALIAS_LOG"\n'
            'exec "$PERSISTENCE_REAL_GO" "$@"\n'
        )
        path.chmod(0o755)
        return path, {
            "PERSISTENCE_ALIAS_LOG": str(log),
            "PERSISTENCE_REAL_GO": str(GO_BINARY),
        }

    def seed_credentials(self, work, kind):
        config = work / "config.json"
        config.write_bytes(b'{"monero":{},"marker":"synthetic"}\n')
        config.chmod(0o640)
        temporary = work / "config.json.tmp"
        if kind == "hardlink":
            os.link(config, temporary)
        else:
            temporary.symlink_to("config.json")

    def test_credential_aliases_match_legacy_bytes_and_status(self):
        for kind in ("hardlink", "symlink"):
            with self.subTest(kind=kind):
                baseline = self.work(kind + "-credentials-bash")
                selected = self.work(kind + "-credentials-go")
                self.seed_credentials(baseline, kind)
                self.seed_credentials(selected, kind)
                expected = self.invoke("bash", baseline, "credentials", "u", "p")
                actual = self.invoke("go", selected, "credentials", "u", "p")
                self.assertEqual(actual, expected)

    def test_credential_alias_guard_skips_native_helper(self):
        baseline = self.work("credential-spy-bash")
        selected = self.work("credential-spy-go")
        self.seed_credentials(baseline, "hardlink")
        self.seed_credentials(selected, "hardlink")
        log = self.directory / "credential-spy.log"
        spy, extra = self.spy("credential-spy-bin", log)
        expected = self.invoke("bash", baseline, "credentials", "u", "p")
        actual = self.invoke("go", selected, "credentials", "u", "p", binary=spy, extra=extra)
        self.assertEqual(actual, expected)
        self.assertFalse(log.exists())

    def seed_appliance(self, work, kind):
        (work / "config.json").write_bytes(b'{"original":true}\n')
        alternate = work / "alt.json"
        alternate.write_bytes(b'{"dashboard":{"auth":{"password":"pass"}}}\n')
        alternate.chmod(0o640)
        temporary = work / "defaults.tmp"
        if kind == "hardlink":
            os.link(alternate, temporary)
        else:
            temporary.symlink_to("alt.json")

    def test_appliance_explicit_path_aliases_match_legacy(self):
        extra = {"CONFIG_PERSISTENCE_FIXED_TMP": "1"}
        for kind in ("hardlink", "symlink"):
            with self.subTest(kind=kind):
                baseline = self.work(kind + "-appliance-bash")
                selected = self.work(kind + "-appliance-go")
                self.seed_appliance(baseline, kind)
                self.seed_appliance(selected, kind)
                expected = self.invoke("bash", baseline, "defaults", "alt.json", extra=extra)
                actual = self.invoke("go", selected, "defaults", "alt.json", extra=extra)
                self.assertEqual(actual, expected)

    def test_appliance_alias_guard_skips_native_helper(self):
        baseline = self.work("appliance-spy-bash")
        selected = self.work("appliance-spy-go")
        self.seed_appliance(baseline, "hardlink")
        self.seed_appliance(selected, "hardlink")
        log = self.directory / "appliance-spy.log"
        spy, extra = self.spy("appliance-spy-bin", log)
        extra["CONFIG_PERSISTENCE_FIXED_TMP"] = "1"
        expected = self.invoke(
            "bash", baseline, "defaults", "alt.json", extra={"CONFIG_PERSISTENCE_FIXED_TMP": "1"}
        )
        actual = self.invoke("go", selected, "defaults", "alt.json", binary=spy, extra=extra)
        self.assertEqual(actual, expected)
        self.assertFalse(log.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
