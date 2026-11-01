import copy
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/env_render_reference.sh"
FIXTURES = ROOT / "tests/stack/fixtures/config-2.0.0"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

VIEW_KEY = "01" + "00" * 31
MONERO_WALLET = "44yQXfkWZNmJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmJ7suhUXwdrDJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmCYrSgjJ"
TARI_WALLET = (
    "12M2aZjsSvTTcaFyzLxARkvwdxv8UHJeJBA6E1pEoP967ydCL8tv17vktNDHhqDgFg5LxtHrp9Wsd1cuhyW1p6fzimM"
)
TARI_SPEND_KEY = "e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76"


class EnvRenderParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.base_config = json.loads((FIXTURES / "absent.json").read_text())

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            PITHEAD_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
        )
        env.update(extra or {})
        return env

    def reference(self, pairs):
        payload = b"".join(key + b"\0" + value + b"\0" for key, value in pairs)
        return subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), "serialize"],
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def quote_reference(self, value):
        return subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), "quote"],
            env={**os.environ, "ENV_RENDER_VALUE": value.decode()},
            capture_output=True,
            check=False,
            timeout=15,
        )

    def helper(self, payload):
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY)],
            env={**os.environ, "PITHEAD_GO_HELPER": "config-env"},
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def framed(self, pairs, status=b"0"):
        body = b"".join(key + b"\0" + value + b"\0" for key, value in pairs)
        return body + b"\0" + status + b"\0"

    def make_spy(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -Eeuo pipefail\n" + body)
        path.chmod(0o755)
        return path

    def test_bulk_serialization_matches_dotenv_renderer(self):
        pairs = [
            (b"PLAIN", b"alpha beta#gamma"),
            (b"EMPTY", b""),
            (b"LEADING", b" value"),
            (b"TRAILING", b"value "),
            (b"COMMENT", b"value #comment"),
            (b"DOLLAR", b"$HOME ${TOKEN}"),
            (b"QUOTES", b"double\" and single'"),
            (b"SLASH", b"one\\two"),
            (b"TAB", b"one\ttwo"),
            (b"NEWLINE", b"one\ntwo"),
            (b"CARRIAGE", b"one\rtwo"),
            (b"TRAILING_LF", b"tail\n"),
            (b"UNICODE", "café 東京".encode()),
        ]
        baseline = self.reference(pairs)
        selected = self.helper(self.framed(pairs))
        self.assertEqual(baseline.returncode, 0)
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (0, baseline.stdout + b".", baseline.stderr),
        )

    def test_quote_corpus_matches_one_value_at_a_time(self):
        values = [
            b"plain",
            b"",
            b" leading",
            b"trailing ",
            b"middle space",
            b"middle # comment",
            b"$dollar",
            b'"double"',
            b"'single'",
            b"back\\slash",
            b"tab\there",
            b"line\nfeed",
            b"carriage\rreturn",
            b"tail\n",
            "naïve-東京".encode(),
        ]
        for index, value in enumerate(values):
            with self.subTest(index=index):
                pair = [(b"VALUE", value)]
                baseline = self.quote_reference(value)
                selected = self.helper(self.framed(pair))
                self.assertEqual(
                    (selected.returncode, selected.stdout, selected.stderr),
                    (baseline.returncode, b"VALUE=" + baseline.stdout + b"\n.", baseline.stderr),
                )

    def test_malformed_frames_and_unsupported_values_refuse_silently(self):
        cases = {
            "empty": b"",
            "missing-footer": b"GOOD\0value\0",
            "failed-footer": self.framed([(b"GOOD", b"value")], b"17"),
            "empty-batch": b"\0" + b"0\0",
            "unterminated": b"GOOD\0value\0\0" + b"0",
            "odd-pair": b"GOOD\0\0" + b"0\0",
            "empty-key": self.framed([(b"", b"value")]),
            "lowercase-key": self.framed([(b"bad", b"value")]),
            "digit-key": self.framed([(b"1BAD", b"value")]),
            "punctuation-key": self.framed([(b"BAD-KEY", b"value")]),
            "duplicate-key": self.framed([(b"GOOD", b"one"), (b"GOOD", b"two")]),
            "invalid-key-utf8": self.framed([(b"BAD\xff", b"value")]),
            "invalid-value-utf8": self.framed([(b"GOOD", b"bad\xff")]),
            "unicode-space": self.framed([(b"GOOD", "a\u00a0b".encode())]),
            "unicode-control": self.framed([(b"GOOD", "a\u0085b".encode())]),
            "unicode-format": self.framed([(b"GOOD", "a\u200eb".encode())]),
        }
        for name, payload in cases.items():
            with self.subTest(case=name):
                result = self.helper(payload)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def render_cases(self):
        remote = copy.deepcopy(self.base_config)
        remote["monero"].update(
            mode="remote",
            remote={"host": "node.example.com", "rpc_port": 28081, "zmq_port": 28083},
        )
        remote["tari"].update(
            mode="remote", remote={"host": "tari.example.com", "grpc_port": 28142}
        )

        tari_off = copy.deepcopy(self.base_config)
        tari_off["tari"]["mode"] = "off"

        profiles = copy.deepcopy(self.base_config)
        profiles["monero"].update(mode="local", wallet_address=MONERO_WALLET, view_key=VIEW_KEY)
        profiles["tari"].update(
            mode="local",
            wallet_address=TARI_WALLET,
            view_key=VIEW_KEY,
            spend_public_key=TARI_SPEND_KEY,
        )

        custom = copy.deepcopy(self.base_config)
        custom_value = "rpc $dollar \\\"double\\\" 'single' \\\\ path"
        custom["monero"]["node_password"] = custom_value
        custom["p2pool"] = {"pool": "main", "clearnet": True, "stratum_port": 4444}
        unicode_space = copy.deepcopy(self.base_config)
        unicode_value = "rpc\u00a0password"
        unicode_space["monero"]["node_password"] = unicode_value

        return {
            "diy-local": (self.base_config, "0", False, {}),
            "c-locale": (self.base_config, "0", False, {"LC_ALL": "C"}),
            "appliance-defaults": (self.base_config, "1", False, {}),
            "remote-nodes": (remote, "0", False, {}),
            "tari-off": (tari_off, "0", False, {}),
            "payout-profiles": (profiles, "0", False, {}),
            "custom-parameters": (custom, "0", False, {}),
            "unicode-space-fallback": (unicode_space, "0", True, {}),
        }

    def invoke_render(self, implementation, name, config, platform, binary=None, extra=None):
        install = self.directory / f"{name}-{implementation}"
        install.mkdir()
        config_file = install / "fixture.json"
        config_file.write_text(json.dumps(config, ensure_ascii=False))
        result = subprocess.run(  # noqa: S603
            [
                BASH,
                str(FIXTURES / "render.sh"),
                str(ROOT / "pithead"),
                str(config_file),
                platform,
                "platform-defaults" if platform == "1" else "",
            ],
            cwd=install,
            env=self.environment(implementation, binary, extra),
            capture_output=True,
            check=False,
            timeout=30,
        )
        env_file = install / ".env"
        secret_file = install / "data/tari-wallet-secret.env"

        def normalize(data):
            return data.replace(str(install).encode(), b"@ROOT@")

        return {
            "process": (result.returncode, normalize(result.stdout), normalize(result.stderr)),
            "env": normalize(env_file.read_bytes()) if env_file.exists() else None,
            "env_mode": stat.S_IMODE(env_file.stat().st_mode) if env_file.exists() else None,
            "secret": normalize(secret_file.read_bytes()) if secret_file.exists() else None,
            "secret_mode": stat.S_IMODE(secret_file.stat().st_mode)
            if secret_file.exists()
            else None,
        }

    def test_complete_render_matches_reference_and_uses_one_native_batch(self):
        for name, (config, platform, fallback, case_env) in self.render_cases().items():
            with self.subTest(case=name):
                log = self.directory / f"{name}.spy"
                spy = self.make_spy(
                    f"{name}-spy",
                    'if "$ENV_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
                    'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "$rc" '
                    '>>"$ENV_SPY_LOG"\nexit "$rc"\n',
                )
                baseline = self.invoke_render("bash", name, config, platform)
                selected = self.invoke_render(
                    "go",
                    name,
                    config,
                    platform,
                    spy,
                    {
                        **case_env,
                        "ENV_REAL_GO": str(GO_BINARY),
                        "ENV_SPY_LOG": str(log),
                    },
                )
                self.assertEqual(selected, baseline)
                entries = log.read_text().splitlines()
                expected = "config-env:0:125" if fallback else "config-env:0:0"
                self.assertEqual(entries.count(expected), 1)
                self.assertNotIn(config["monero"]["node_password"], log.read_text())
                self.assertEqual(baseline["env_mode"], 0o600)
                self.assertEqual(baseline["env"].count(b"\n"), 133)
                self.assertEqual(baseline["secret_mode"], 0o600)
                if name == "payout-profiles":
                    self.assertIn(VIEW_KEY.encode(), baseline["secret"])
                    self.assertNotIn(VIEW_KEY, log.read_text())

    def invoke_render_failure(self, implementation, name, target_case, binary=None, extra=None):
        install = self.directory / f"failure-{name}-{implementation}"
        install.mkdir()
        config_file = install / "fixture.json"
        config_file.write_text(json.dumps(self.base_config))
        target = install / "target.env"
        if target_case == "directory":
            target.mkdir()
        elif target_case == "missing-parent":
            target = install / "missing" / "target.env"
        elif target_case == "read-only":
            target.write_bytes(b"preserved\n")
            target.chmod(0o400)
        elif target_case == "dangling-symlink":
            target.symlink_to(install / "missing" / "target.env")
        else:
            raise ValueError(target_case)

        render_env = {**(extra or {}), "PITHEAD_ENV_FILE": str(target)}
        result = subprocess.run(  # noqa: S603
            [
                BASH,
                str(FIXTURES / "render.sh"),
                str(ROOT / "pithead"),
                str(config_file),
                "0",
            ],
            cwd=install,
            env=self.environment(implementation, binary, render_env),
            capture_output=True,
            check=False,
            timeout=30,
        )
        secret_file = install / "data/tari-wallet-secret.env"

        def normalize(data):
            return data.replace(str(install).encode(), b"@ROOT@")

        if target.is_symlink():
            target_state = ("symlink", normalize(os.readlink(target).encode()))
        elif target.is_dir():
            target_state = ("directory",)
        elif target.exists():
            target_state = (
                "file",
                normalize(target.read_bytes()),
                stat.S_IMODE(target.stat().st_mode),
            )
        else:
            target_state = ("missing",)
        return {
            "process": (result.returncode, normalize(result.stdout), normalize(result.stderr)),
            "secret": normalize(secret_file.read_bytes()) if secret_file.exists() else None,
            "secret_mode": stat.S_IMODE(secret_file.stat().st_mode)
            if secret_file.exists()
            else None,
            "target": target_state,
        }

    def test_failed_targets_keep_reference_diagnostics_without_starting_native_env(self):
        for target_case in ("directory", "missing-parent", "read-only", "dangling-symlink"):
            with self.subTest(target=target_case):
                log = self.directory / f"failure-{target_case}.spy"
                spy = self.make_spy(
                    f"failure-{target_case}-spy",
                    'if "$ENV_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
                    'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "$rc" '
                    '>>"$ENV_SPY_LOG"\nexit "$rc"\n',
                )
                baseline = self.invoke_render_failure("bash", target_case, target_case)
                selected = self.invoke_render_failure(
                    "go",
                    target_case,
                    target_case,
                    spy,
                    {"ENV_REAL_GO": str(GO_BINARY), "ENV_SPY_LOG": str(log)},
                )
                self.assertEqual(selected, baseline)
                if baseline["secret"] is not None:
                    self.assertEqual(baseline["secret_mode"], 0o600)
                env_entries = [
                    entry
                    for entry in log.read_text().splitlines()
                    if entry.startswith("config-env:")
                ]
                if target_case == "read-only" and baseline["process"][0] == 0:
                    self.assertEqual(env_entries, ["config-env:0:0"])
                else:
                    self.assertNotEqual(baseline["process"][0], 0)
                    self.assertEqual(env_entries, [])

    def test_refusal_and_missing_binary_fall_back(self):
        config = self.base_config
        baseline = self.invoke_render("bash", "fallback-baseline", config, "0")

        refused_log = self.directory / "refused.log"
        refused = self.make_spy(
            "refused",
            'printf "%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" >>"$ENV_REFUSED_LOG"\nexit 125\n',
        )
        selected = self.invoke_render(
            "go",
            "fallback-refused",
            config,
            "0",
            refused,
            {"ENV_REFUSED_LOG": str(refused_log)},
        )
        self.assertEqual(selected, baseline)
        self.assertEqual(refused_log.read_text().splitlines().count("config-env:0"), 1)

        poison_log = self.directory / "poison.log"
        poison = self.make_spy("poison", 'printf called >"$ENV_POISON_LOG"\nexit 99\n')
        selected = self.invoke_render(
            "go",
            "fallback-missing",
            config,
            "0",
            self.directory / "missing-go",
            {
                "PITHEAD_GO_CONFIG_DOCUMENT_BINARY": str(poison),
                "ENV_POISON_LOG": str(poison_log),
            },
        )
        self.assertEqual(selected, baseline)
        self.assertFalse(poison_log.exists())


if __name__ == "__main__":
    unittest.main()
