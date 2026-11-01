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
ADAPTER = ROOT / "tests/go-parity/env_dashboard_reference.sh"
FIXTURES = ROOT / "tests/stack/fixtures/config-2.0.0"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class EnvDashboardParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.base_config = json.loads((FIXTURES / "absent.json").read_text())

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(PITHEAD_IMPL=implementation, PITHEAD_GO_BINARY=str(binary or GO_BINARY))
        env.update(extra or {})
        return env

    def make_spy(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -Eeuo pipefail\n" + body)
        path.chmod(0o755)
        return path

    def forwarding_spy(self, name):
        return self.make_spy(
            name,
            'if "$DASHBOARD_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "$rc" '
            '>>"$DASHBOARD_SPY_LOG"\nexit "$rc"\n',
        )

    def invoke(self, implementation, name, config, platform="0", binary=None, extra=None):
        install = self.directory / f"{name}-{implementation}"
        install.mkdir()
        config_file = install / "fixture.json"
        if isinstance(config, str):
            config_file.write_text(config)
        else:
            config_file.write_text(json.dumps(config))
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

    def defaults_table(self):
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT)],
            env={key: value for key, value in os.environ.items() if key != "BASH_ENV"},
            capture_output=True,
            check=False,
            timeout=15,
        )
        self.assertEqual((result.returncode, result.stderr), (0, b""))
        return result.stdout

    def frame(self, config, status=b"0"):
        values = [
            b"diy",
            b"local",
            self.base_config["monero"]["wallet_address"].encode(),
            self.defaults_table(),
            config,
            status,
        ]
        return b"\0".join(values) + b"\0"

    def helper(self, payload, args=()):
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), *args],
            env={**os.environ, "PITHEAD_GO_HELPER": "config-env-dashboard"},
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def assert_fixture_parity(self, name, config, platform="0", expected_status=0, secrets=()):
        log = self.directory / f"{name}.log"
        spy = self.forwarding_spy(f"{name}-spy")
        baseline = self.invoke("bash", name, config, platform)
        selected = self.invoke(
            "go",
            name,
            config,
            platform,
            spy,
            {
                "DASHBOARD_REAL_GO": str(GO_BINARY),
                "DASHBOARD_SPY_LOG": str(log),
            },
        )
        self.assertEqual(selected, baseline)
        entries = log.read_text().splitlines()
        self.assertEqual(entries.count(f"config-env-dashboard:0:{expected_status}"), 1)
        for secret in secrets:
            self.assertNotIn(secret, log.read_text())
        self.assertEqual(baseline["process"][0], 0)
        self.assertEqual(baseline["env_mode"], 0o600)
        self.assertEqual(baseline["secret_mode"], 0o600)
        return baseline, entries

    def test_private_protocol_returns_52_fields_and_refuses_bad_frames(self):
        raw = (FIXTURES / "absent.json").read_bytes()
        valid = self.frame(raw)
        result = self.helper(valid)
        fields = result.stdout.split(b"\0")
        self.assertEqual(
            (result.returncode, result.stderr, len(fields), fields[-1]), (0, b"", 53, b"")
        )
        self.assertEqual(
            [fields[index] for index in (0, 1, 2, 3, 5, 9, 10, 13, 14, 45, 46, 47, 51)],
            [
                b"true",
                b"true",
                b"na.xmrvsbeast.com:4247",
                self.base_config["monero"]["wallet_address"][:8].encode(),
                b"true",
                b"true",
                b"8080",
                b"{}",
                b"false",
                b"50",
                b"10",
                b"08:00",
                b"true",
            ],
        )
        cases = {
            "empty": b"",
            "missing-footer": b"\0".join(valid.split(b"\0")[:-3]) + b"\0",
            "failed-producer": self.frame(raw, b"9"),
            "extra-field": valid + b"extra\0",
            "bad-defaults": valid.replace(self.defaults_table(), b"{", 1),
            "bad-config": self.frame(b"{"),
            "unterminated": valid[:-1],
        }
        for name, payload in cases.items():
            with self.subTest(case=name):
                refused = self.helper(payload)
                self.assertEqual(
                    (refused.returncode, refused.stdout, refused.stderr), (125, b"", b"")
                )
        refused = self.helper(valid, ("unexpected",))
        self.assertEqual((refused.returncode, refused.stdout, refused.stderr), (125, b"", b""))

    def test_sparse_legacy_and_appliance_defaults_match(self):
        for name, platform in (("sparse-legacy", "0"), ("appliance-defaults", "1")):
            with self.subTest(case=name):
                self.assert_fixture_parity(name, self.base_config, platform)

    def test_explicit_false_null_strings_and_donor_modes_match(self):
        config = copy.deepcopy(self.base_config)
        config["xvb"] = {
            "enabled": False,
            "tor": None,
            "url": "",
            "donor_id": "DYNAMIC_ID",
            "donation_level": "",
        }
        config["dashboard"].update(tari_required=False, fail_closed="YES", check_for_updates=None)
        config["telegram"] = {
            "enabled": "false",
            "commands": {"enabled": None},
            "events": {"node_down": None, "node_recovered": "off"},
        }
        config["notifications"] = {"tor": False, "webhooks": [], "ntfy": None}
        baseline, _ = self.assert_fixture_parity("false-null-strings", config)
        self.assertIn(
            b"XVB_DONOR_ID=" + config["monero"]["wallet_address"][:8].encode(), baseline["env"]
        )
        self.assertIn(b"DASHBOARD_FAIL_CLOSED=true\n", baseline["env"])
        self.assertIn(b"TELEGRAM_EVENT_NODE_RECOVERED=off\n", baseline["env"])

    def test_worker_tokens_first_duplicate_and_literal_donor_match(self):
        config = copy.deepcopy(self.base_config)
        fleet = 'fleet"$\\token'
        first = 'first"$\\token'
        second = "second-token"
        config["xvb"] = {
            "enabled": True,
            "tor": False,
            "url": "pool.example:4242",
            "donor_id": "literal-donor",
            "donation_level": "whale",
            "standby": {"source": "https://user:pass@dash.invalid/api/xvb-standby"},
        }
        config["workers"] = {
            "api_port": 8123,
            "api_auth": "token",
            "api_token": fleet,
            "list": [
                {"name": "rig-a", "host": "10.0.0.2", "port": 9001, "api_token": first},
                {"name": "rig-a", "host": "10.0.0.3", "port": 9002, "api_token": second},
                {"name": "skip", "host": "10.0.0.4"},
                {"name": "rig-b", "host": "rig-b.lan", "api_token": "last-token"},
            ],
        }
        baseline, _ = self.assert_fixture_parity(
            "workers-donor", config, secrets=(fleet, first, second, "last-token")
        )
        self.assertIn(b"XVB_DONOR_ID=literal-donor\n", baseline["env"])
        worker_line = next(
            line for line in baseline["env"].splitlines() if line.startswith(b"WORKER_API_TOKENS=")
        )
        self.assertIn(b"10.0.0.2", worker_line)
        self.assertIn(b"9001", worker_line)
        self.assertNotIn(b"10.0.0.3", worker_line)
        self.assertIn(b"rig-b.lan", worker_line)
        self.assertIn(b"8123", worker_line)
        self.assertLess(worker_line.index(b"rig-a"), worker_line.index(b"rig-b"))

    def test_telegram_events_notifications_and_quoted_secrets_match(self):
        config = copy.deepcopy(self.base_config)
        secrets = ("bot$token", 'ntfy"$token', "health$token")
        event_keys = (
            "node_down",
            "node_recovered",
            "worker_offline",
            "worker_recovered",
            "worker_joined",
            "worker_left",
            "sync_finished",
            "disk_space",
            "db_unhealthy",
            "db_reset",
            "xvb_no_share",
            "clearnet_exposed",
            "xvb_registration",
            "new_release",
            "stack_online",
            "daily_summary",
            "hashrate_low",
            "hashrate_loss",
            "hugepages",
            "low_ram",
            "wallet_changed",
            "high_reject_rate",
            "block_found",
            "payout_found",
            "payout_confirmed",
            "container_unhealthy",
            "raffle_win",
        )
        events = {key: f"event-{index}" for index, key in enumerate(event_keys)}
        events.update(node_down=False, worker_joined="sometimes", raffle_win=None)
        config["dashboard"].update(hashrate_drop_threshold=37, hashrate_drop_minutes=5)
        config["healthchecks"] = {"ping_url": "https://hc.invalid/health$token"}
        config["telegram"] = {
            "enabled": True,
            "bot_token": "bot$token",
            "chat_id": "-123",
            "commands": {"enabled": True},
            "daily_summary_time": "07:30",
            "events": events,
        }
        config["notifications"] = {
            "webhooks": [
                'https://hooks.invalid/a?token=$x&quote="q"',
                "http://notify.invalid/second",
            ],
            "ntfy": {"url": "https://ntfy.invalid/topic", "token": 'ntfy"$token'},
            "tor": False,
        }
        baseline, _ = self.assert_fixture_parity("telegram-notifications", config, secrets=secrets)
        self.assertIn(b"TELEGRAM_EVENT_NODE_DOWN=false\n", baseline["env"])
        self.assertIn(b"TELEGRAM_EVENT_WORKER_JOINED=sometimes\n", baseline["env"])
        self.assertIn(b"HASHRATE_DROP_THRESHOLD_PCT=37\n", baseline["env"])

    def test_unsupported_decimal_falls_back_to_bash(self):
        config = copy.deepcopy(self.base_config)
        config["dashboard"]["hashrate_drop_threshold"] = 37.0
        baseline, entries = self.assert_fixture_parity(
            "decimal-threshold", config, expected_status=125
        )
        self.assertIn(b"HASHRATE_DROP_THRESHOLD_PCT=37.0\n", baseline["env"])
        self.assertIn("config-env:0:0", entries)

    def test_malformed_successful_plan_falls_back(self):
        poisoned = (
            '"$DASHBOARD_REAL_GO" "$@" | '
            "{ IFS= read -r -d '' discarded; printf 'poison\\0'; cat; }"
        )
        cases = {
            "trailing": poisoned + "; printf '0\\0trailing'",
            "extra": poisoned + "; printf '0\\0extra\\0'",
            "empty": poisoned + "; printf '0\\0\\0'",
        }
        baseline = self.invoke("bash", "poison-baseline", self.base_config)
        for name, output in cases.items():
            with self.subTest(case=name):
                log = self.directory / f"poison-{name}.log"
                spy = self.make_spy(
                    f"poison-{name}-spy",
                    'if [ "${PITHEAD_GO_HELPER:-}" = config-env-dashboard ]; then\n'
                    f'  printf "config-env-dashboard:%s:{name}\\n" "$#" '
                    '>>"$DASHBOARD_SPY_LOG"\n'
                    f"  {output}\n"
                    "  exit 0\n"
                    "fi\n"
                    'exec "$DASHBOARD_REAL_GO" "$@"\n',
                )
                selected = self.invoke(
                    "go",
                    f"poison-{name}",
                    self.base_config,
                    binary=spy,
                    extra={
                        "DASHBOARD_REAL_GO": str(GO_BINARY),
                        "DASHBOARD_SPY_LOG": str(log),
                    },
                )
                self.assertEqual(selected, baseline)
                self.assertEqual(log.read_text().splitlines(), [f"config-env-dashboard:0:{name}"])


if __name__ == "__main__":
    unittest.main()
