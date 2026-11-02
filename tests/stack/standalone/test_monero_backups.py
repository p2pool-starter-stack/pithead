import base64
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(os.environ.get("PITHEAD_BACKUP_TEST_ROOT", Path(__file__).resolve().parents[3]))
BASH = "/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").exists() else "bash"
NODE = {"host": "backup.example", "rpc_port": 28081, "zmq_port": 28083}


class BackupContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config.json"
        (self.root / "config.reference.json").write_text(
            (ROOT / "config.reference.json").read_text()
        )

    def shell(self, command, config=None, driver=None):
        self.config.write_text(json.dumps(config or {"monero": {"backup_nodes": []}}))
        script = """source "$1" >/dev/null
PITHEAD_DRY_RUN=1
remote_node_address() { printf 192.168.1.20; }
NETWORK_PREFIX=172.28.0
MONERO_MODE=remote
MONERO_REMOTE_HOST=primary.example
MONERO_REMOTE_RPC_PORT=18081
MONERO_REMOTE_ZMQ_PORT=18083
error() { printf '%s\\n' "$*" >&2; exit 1; }
"""
        return subprocess.run(  # noqa: S603
            [
                BASH,
                "-c",
                script + command,
                str(driver) if driver else "test",
                str(ROOT / "pithead"),
                str(self.config),
            ],
            cwd=self.root,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def test_validation(self):
        for nodes in [
            None,
            {},
            "node",
            ["node"],
            [dict(NODE, rpc_port="28081")],
            [dict(NODE, zmq_port=0)],
            [dict(NODE, rpc_port=True)],
            [dict(NODE, rpc_port=1.5)],
            [dict(NODE, host="host,fork")],
            [dict(NODE, rpc_ssl=True)],
            [dict(NODE, rpc_login={})],
            [dict(NODE, rpc_login=":secret")],
            [dict(NODE, rpc_login=":")],
            [NODE, NODE],
            [dict(NODE, host="primary.example", rpc_port=18081, zmq_port=18083)],
        ]:
            with self.subTest(nodes=nodes):
                result = self.shell("validate_monero_backups", {"monero": {"backup_nodes": nodes}})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("monero.backup_nodes", result.stderr)
        self.assertEqual(self.shell("validate_monero_backups").returncode, 0)
        self.assertEqual(self.shell("validate_monero_backups", {"monero": {}}).returncode, 0)
        self.assertEqual(
            self.shell("validate_monero_backups", {"monero": {"backup_nodes": [NODE]}}).returncode,
            0,
        )
        for login in ("", "alice", "alice:", "alice:pass:word"):
            with self.subTest(login=login):
                result = self.shell(
                    "validate_monero_backups",
                    {"monero": {"backup_nodes": [dict(NODE, rpc_login=login)]}},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
        result = self.shell(
            "MONERO_MODE=local; validate_monero_backups",
            {
                "monero": {
                    "backup_nodes": [dict(NODE, host="172.28.0.26", rpc_port=18081, zmq_port=18083)]
                }
            },
        )
        self.assertNotEqual(result.returncode, 0)

    def test_encoded_args_preserve_credentials_and_order(self):
        login = 'user:pass with $HOME "quotes" \\ %H --wallet INJECTED'
        nodes = [dict(NODE, rpc_login=login), dict(NODE, host="third.example", rpc_port=38081)]
        result = self.shell(
            "validate_monero_backups; monero_backup_args", {"monero": {"backup_nodes": nodes}}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = [base64.b64decode(value).decode() for value in result.stdout.split()]
        self.assertEqual(
            args,
            [
                "--host",
                NODE["host"],
                "--rpc-port",
                "28081",
                "--zmq-port",
                "28083",
                "--rpc-login",
                login,
                "--host",
                "third.example",
                "--rpc-port",
                "38081",
                "--zmq-port",
                "28083",
            ],
        )
        self.assertEqual(self.shell("monero_backup_args").stdout.strip(), "")

    def test_address_policy_and_unavailable_backup_warning(self):
        cfg = {"monero": {"backup_nodes": [NODE, dict(NODE, host="other.example")]}}
        script = '''remote_node_address() { case "$2" in backup.example) return 1 ;; *) printf '192.168.1.20' ;; esac; }
monero_backup_addresses_allowed "$CONFIG_FILE"'''
        result = self.shell(script, cfg)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("monero.backup_nodes[0]", result.stdout)
        result = self.shell(script.replace("return 1", "return 2"), cfg)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not resolve", result.stdout)
        script = '''remote_node_address() { printf '192.168.1.20'; }
monero_rpc_speaks() { NODE_PROBE_REASON=auth; return 1; }
warn() { printf '%s\\n' "$*"; }
preflight_monero_backups "$CONFIG_FILE"'''
        result = self.shell(script, cfg)
        self.assertEqual(result.returncode, 0)
        self.assertIn("monero.backup_nodes[0] is unavailable (auth)", result.stdout)
        self.assertIn("monero.backup_nodes[1] is unavailable (auth)", result.stdout)

    def test_entrypoint_bridges_individual_host_groups(self):
        binary = self.root / "p2pool"
        binary.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n')
        binary.chmod(0o700)
        socat = self.root / "socat"
        socat.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$SOCAT_LOG"\n')
        socat.chmod(0o700)
        for count in (1, 2, 3):
            with self.subTest(count=count):
                log = self.root / "socat.log"
                log.write_text("")
                args = []
                for i in range(count):
                    args += [
                        "--host",
                        f"node{i}.example",
                        "--rpc-port",
                        "18081",
                        "--zmq-port",
                        "18083",
                        "--rpc-login",
                        f'--user{i}:secret with spaces "quotes"',
                    ]
                backup = args[8:]
                encoded = " ".join(base64.b64encode(a.encode()).decode() for a in backup)
                env = dict(
                    os.environ,
                    PATH=f"{self.root}:{os.environ['PATH']}",
                    SOCAT_LOG=str(log),
                    P2POOL_FLAGS="--socks5 proxy.example:9050",
                    P2POOL_BACKUP_ARGS_B64=encoded,
                )
                result = subprocess.run(  # noqa: S603
                    [BASH, str(ROOT / "build/p2pool/entrypoint.sh"), *args[:8]],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                output = result.stdout.splitlines()
                launch = next(line for line in output if "launching:" in line)
                self.assertNotIn("secret", launch)
                argv = output[output.index(launch) + 1 :]
                expected = list(args)
                for i in range(count):
                    expected[i * 8 + 1] = f"127.0.0.{i + 1}"
                self.assertEqual(argv, expected + ["--socks5", "proxy.example:9050"])
                listeners = sorted(log.read_text().splitlines())
                self.assertEqual(
                    listeners,
                    sorted(
                        f"TCP-LISTEN:{port},bind=127.0.0.{i + 1},fork,reuseaddr TCP:node{i}.example:{port}"
                        for i in range(count)
                        for port in (18081, 18083)
                    ),
                )

    def test_quadlet_transports_the_same_backup_arguments(self):
        args = self.shell("monero_backup_args", {"monero": {"backup_nodes": [NODE]}}).stdout.strip()
        env_file = self.root / "fixture.env"
        env_file.write_text(
            (ROOT / "os/quadlet/fixture.env").read_text() + f'\nP2POOL_BACKUP_ARGS_B64="{args}"\n'
        )
        out = self.root / "quadlet"
        out.mkdir(mode=0o755)
        out.chmod(0o755)
        for name in ("p2pool.container", "dashboard.container"):
            (out / name).touch(mode=0o644)
            (out / name).chmod(0o644)
        result = self.shell(
            f'umask 022; render_quadlet_units "{env_file}" "{out}" && test "$(umask)" = 0022'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(out.stat().st_mode & 0o777, 0o700)
        for unit in out.iterdir():
            self.assertEqual(unit.stat().st_mode & 0o777, 0o600)
        self.assertIn(f'"P2POOL_BACKUP_ARGS_B64={args}"', (out / "p2pool.container").read_text())

    def test_unchanged_endpoint_restores_the_live_credential_at_preview(self):
        node = dict(NODE, rpc_login='user:secret with "quotes" $value')
        candidate = self.root / "request.json"
        candidate.write_text(
            json.dumps(
                {
                    "config": {
                        "monero": {"backup_nodes": [dict(node, rpc_login={"__secret__": True})]}
                    }
                }
            )
        )
        driver = self.root / "dry-run"
        driver.write_text("#!/usr/bin/env bash\nexit 0\n")
        driver.chmod(0o700)
        result = self.shell(
            f'mkdir -p control/staged control/results control/audit; control_preview "{candidate}" restore admin control',
            {"monero": {"backup_nodes": [node]}},
            driver=driver,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads((self.root / "control/results/restore.json").read_text())
        self.assertEqual(response["status"], "previewed")
        staged = json.loads((self.root / "control/staged/restore.json").read_text())
        self.assertEqual(staged["monero"]["backup_nodes"], [node])
        self.assertNotIn("secret with", json.dumps(response))

    def test_masking_and_destination_binding(self):
        node = dict(NODE, rpc_login="user:backup-secret")
        result = self.shell(
            '''CONTROL_DIR="$PWD/control"; mkdir -p "$CONTROL_DIR/masked"
render_masked_config "$CONTROL_DIR"
cat "$CONTROL_DIR/masked/config.json"''',
            {"monero": {"backup_nodes": [node]}},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("backup-secret", result.stdout)
        self.assertIn('"__secret__": true', result.stdout)
        candidate = self.root / "request.json"
        candidate.write_text(
            json.dumps(
                {
                    "config": {
                        "monero": {
                            "backup_nodes": [
                                dict(node, rpc_login={"__secret__": True}, host="changed.example")
                            ]
                        }
                    }
                }
            )
        )
        result = self.shell(
            f'control_masked_binding_error "{candidate}"', {"monero": {"backup_nodes": [node]}}
        )
        self.assertIn("changed while its credentials were masked", result.stdout)


if __name__ == "__main__":
    unittest.main()
