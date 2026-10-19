import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
GUARD = ROOT / "tests/stack/lib/host-guard.sh"
BASH = shutil.which("bash")


class HostIsolation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.host = self.base / "host"
        self.host.mkdir()
        for name in ("egress.service", "egress.timer", "enabled", "iptables", "nft"):
            (self.host / name).write_text("pre-existing " + name + "\n")
        self.before = {p.name: p.read_bytes() for p in self.host.iterdir()}
        host_bin = self.base / "host-bin"
        host_bin.mkdir()
        for name in (
            "sudo",
            "systemctl",
            "iptables",
            "iptables-save",
            "iptables-restore",
            "ip6tables",
            "nft",
        ):
            tool = host_bin / name
            tool.write_text('#!/usr/bin/env bash\nprintf leaked >"$HOST_FIXTURE/enabled"\n')
            tool.chmod(0o755)

        self.sandbox = self.base / "sandbox"
        self.sandbox.mkdir()
        self.env = {
            **os.environ,
            "SANDBOX": str(self.sandbox),
            "HOST_FIXTURE": str(self.host),
            "GUARD": str(GUARD),
            "PATH": str(host_bin) + os.pathsep + os.environ["PATH"],
            "STACK": str(ROOT / "pithead"),
        }

    def run_guard(self, body):
        return subprocess.run(  # noqa: S603
            [
                BASH,
                "-c",
                'set -eu; source "$GUARD"; stack_host_guard_init "$SANDBOX"; '
                "trap stack_sandbox_cleanup EXIT; " + body,
            ],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
        )

    def assert_host_preserved(self):
        self.assertEqual({p.name: p.read_bytes() for p in self.host.iterdir()}, self.before)

    def test_host_double_detects_a_missing_guard(self):
        result = subprocess.run(  # noqa: S603
            [BASH, "-c", "systemctl enable --now pithead-egress.timer"],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.host / "enabled").read_text(), "leaked")

    def test_undeclared_commands_fail_even_when_the_caller_ignores_errors(self):
        for command in (
            'sudo tee "$HOST_FIXTURE/egress.service" </dev/null',
            "systemctl enable --now pithead-egress.timer",
            "iptables -A DOCKER-USER -j DROP",
            "iptables-restore </dev/null",
            "ip6tables -F",
            "nft -f - </dev/null",
        ):
            with self.subTest(command=command):
                result = self.run_guard(command + " >/dev/null 2>&1 || true; exit 0")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("undeclared host commands were blocked", result.stderr)
                self.assert_host_preserved()
                self.sandbox.mkdir()

    def test_read_probes_are_unavailable_without_reading_the_host(self):
        result = self.run_guard(
            "systemctl is-active pithead-egress.timer && exit 9; "
            "iptables-save && exit 9; nft -j list tables && exit 9; exit 0"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_host_preserved()

    def test_child_process_cannot_hide_a_blocked_mutation(self):
        result = self.run_guard('bash -c "systemctl daemon-reload" >/dev/null 2>&1 || true; exit 0')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_host_preserved()

    def test_cleanup_preserves_failure_status(self):
        result = self.run_guard("exit 7")
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_real_installers_stay_in_fixtures_on_every_exit(self):
        fixture_bin = self.base / "bin"
        fixture_bin.mkdir()
        scripts = {
            "uname": "echo Linux\n",
            "sudo": """[ "$1" != -n ] || shift
case "$1" in
tee) case "$2" in "$SANDBOX"/units/*) ;; *) exit 125 ;; esac ;;
systemctl|iptables|iptables-save|iptables-restore|nft) ;;
*) exit 125 ;;
esac
exec "$@"
""",
            "systemctl": """printf '%s\n' "$*" >>"$SANDBOX/systemctl.log"
case "$1" in is-*) exit 1 ;; esac
""",
            "iptables": """printf '%s\n' "$*" >>"$SANDBOX/iptables.log"
case "$*" in
"-S FORWARD") echo '-A FORWARD -j DOCKER-USER' ;;
"-S DOCKER-USER") sed -n 's/^-I DOCKER-USER [0-9]* /-A DOCKER-USER /p' "$SANDBOX/rules" ;;
esac
""",
            "iptables-save": 'printf "*filter\n:DOCKER-USER - [0:0]\nCOMMIT\n"\n',
            "iptables-restore": 'cat >"$SANDBOX/rules"\n',
            "nft": 'printf "%s\n" "$*" >>"$SANDBOX/nft.log"\n',
        }
        for name, script in scripts.items():
            file = fixture_bin / name
            file.write_text("#!/usr/bin/env bash\nset -eu\n" + script)
            file.chmod(0o755)
        self.env["FIXTURE_BIN"] = str(fixture_bin)
        for ending, expected in (
            ("exit 0", 0),
            ("exit 7", 7),
            ("trap 'exit 143' TERM; kill -TERM $$", 143),
        ):
            with self.subTest(ending=ending):
                result = self.run_guard(
                    'export PATH="$FIXTURE_BIN:$PATH" PITHEAD_ENGINE=docker; '
                    'cd "$SANDBOX"; source "$STACK"; '
                    'printf "TOR_EGRESS_FIREWALL=true\nMONERO_RPC_BIND=0.0.0.0\n" >.env; '
                    "provision_egress_check_units; provision_lan_guard_check_units; "
                    "apply_tor_egress_iptables 172.28.0.0/24 172.28.0.25; "
                    'test -s "$PITHEAD_UNIT_DIR/pithead-egress-check.service"; '
                    'test -s "$PITHEAD_UNIT_DIR/pithead-egress.timer"; '
                    'test -s "$PITHEAD_UNIT_DIR/pithead-lan-check.service"; '
                    'grep -q "enable --now pithead-egress.timer" systemctl.log; '
                    "grep -q pithead-tor-egress rules; " + ending
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertFalse(self.sandbox.exists())
                self.assert_host_preserved()
                self.sandbox.mkdir()


if __name__ == "__main__":
    unittest.main()
