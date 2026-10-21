import json
import os
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class StratumPortTest(unittest.TestCase):
    def probe(self, port, active=3333, bind="0.0.0.0", action="validate_stratum_port_change"):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text(f"STRATUM_PORT={active}\n")
            config_file = Path(directory) / "config.json"
            config_file.write_text(
                json.dumps({"p2pool": {"stratum_port": port, "stratum_bind": bind}})
            )
            result = subprocess.run(
                [
                    "/bin/bash",
                    "-c",
                    """
set -euo pipefail
source "$ROOT/lib/pithead/19-small-utilities.sh"
source "$ROOT/lib/pithead/22a-config-document.sh"
source "$ROOT/lib/pithead/27b-stratum-endpoint.sh"
source "$ROOT/lib/pithead/39a-stratum-port-preflight.sh"
source "$ROOT/lib/pithead/40-apply-and-render.sh"
error() { echo "$*" >&2; exit 1; }
require_env() { :; }
ensure_onion_password() { echo "reached mutation boundary"; exit 77; }
validate_config_document() { :; }
parse_and_validate_config() { :; }
load_preserved_state() { echo "reached mutation boundary"; exit 77; }
PITHEAD_ENV_DRYRUN="$ENV_FILE.dryrun"
case "$ACTION" in
    preview) apply --dry-run --porcelain ;;
    commit) apply -y ;;
    *) validate_stratum_port_change ;;
esac
""",
                ],
                env={
                    **os.environ,
                    "ROOT": str(ROOT),
                    "ENV_FILE": str(env_file),
                    "CONFIG_FILE": str(config_file),
                    "STRATUM_PORT": str(port),
                    "STRATUM_BIND": bind,
                    "ACTION": action,
                },
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(
                json.loads(config_file.read_text()),
                {"p2pool": {"stratum_port": port, "stratum_bind": bind}},
            )
            self.assertEqual(env_file.read_text(), f"STRATUM_PORT={active}\n")
            return result

    def test_each_occupied_candidate_refused_before_preview_or_commit(self):
        with socket.socket() as first, socket.socket() as second:
            for listener in (first, second):
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                for action in ("preview", "commit"):
                    with self.subTest(port=listener.getsockname()[1], action=action):
                        result = self.probe(listener.getsockname()[1], action=action)
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertIn("already in use", result.stderr)
                        self.assertNotIn("reached mutation boundary", result.stdout)

    def test_unchanged_active_port_allowed(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            self.assertEqual(self.probe(port, active=port).returncode, 0)

    def test_free_changed_port_allowed(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.assertEqual(self.probe(port).returncode, 0)

    def test_specific_bind_conflicts_with_wildcard_listener(self):
        with socket.socket() as listener:
            listener.bind(("0.0.0.0", 0))
            listener.listen()
            result = self.probe(listener.getsockname()[1], bind="127.0.0.1")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("already in use", result.stderr)

    def test_probe_does_not_reserve_port(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.assertEqual(self.probe(port).returncode, 0)
        with socket.socket() as listener:
            listener.bind(("0.0.0.0", port))
            listener.listen()
            result = self.probe(port, action="commit")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("already in use", result.stderr)

    def test_control_characters_refused_before_endpoint_diagnostics(self):
        for action in ("preview", "commit"):
            for port, bind in (
                ("443\nuntrusted-marker", "0.0.0.0"),
                (45678, "\x1b[31muntrusted-marker"),
            ):
                with self.subTest(action=action, port=port, bind=bind):
                    result = self.probe(port, bind=bind, action=action)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("control character", result.stderr)
                    self.assertNotIn("untrusted-marker", result.stderr)

    def test_unavailable_address_fails_closed(self):
        result = self.probe(45678, bind="192.0.2.1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("could not be checked", result.stderr)


if __name__ == "__main__":
    unittest.main()
