import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASH = shutil.which("bash")


class ChainRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        for name in ("one", "two"):
            target = self.base / name / "build/tari"
            target.mkdir(parents=True)
            for file in ("config.toml.template", "entrypoint.sh"):
                shutil.copyfile(ROOT / "build/tari" / file, target / file)
        self.shared = self.base / "shared"
        self.shared.mkdir()

    def run_shell(self, body, checkout="one", success=True):
        script = (
            """
set -euo pipefail
source "$1/lib/pithead/29a-chain-runtime-state.sh"
source "$1/lib/pithead/34-inject-service-configs.sh"
TARI_CONFIG_ROOT="$2/tari-config"
CLEARNET_STATE_DIR="$2/clearnet-state"
LAN_GUARD_DIR="$2/lan-guard"
TARI_ONION=unchanged.onion
NETWORK_PREFIX=172.28.0
log() { :; }
error() { printf '%s\\n' "$*" >&2; exit 1; }
sudo() { if [ "$1" != chown ]; then "$@"; fi; }
docker() { printf '%s\\n' "$*" >>"$2/docker-calls"; }
safe_sed() { sed "$1" "$2" >"$2.tmp"; mv "$2.tmp" "$2"; }
env_get() { case "$1" in
TARI_CONFIG_DIR) chain_runtime_config_dir ;;
CLEARNET_STATE_DIR) printf '%s' "${OLD_STATE:-$CLEARNET_STATE_DIR}" ;;
CONTROL_DIR) printf '%s' "$PWD/control" ;;
esac; }
config_bool() { printf true; }
normalize_bool() { printf '%s' "$1"; }
"""
            + body
        )
        result = subprocess.run(  # noqa: S603
            [BASH, "-c", script, "test", str(ROOT), str(self.shared)],
            cwd=self.base / checkout,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result.stdout.strip()

    def test_move_retains_runtime_identity_and_content(self):
        command = """
prepare_chain_runtime_state
install_chain_runtime_config
chain_runtime_config_dir
"""
        first = self.run_shell(command)
        before = (Path(first) / "config.toml").stat().st_ino
        second = self.run_shell(command, "two")
        self.assertEqual(first, second)
        self.assertEqual(before, (Path(second) / "config.toml").stat().st_ino)
        self.assertNotIn(str(self.base / "one"), first)
        self.assertNotIn(str(self.base / "two"), first)
        self.assertIn("unchanged", (Path(first) / "config.toml").read_text())
        self.assertTrue(os.access(Path(first) / "entrypoint.sh", os.X_OK))

    def test_changed_runtime_inputs_select_a_new_identity(self):
        first = self.run_shell("chain_runtime_config_dir")
        self.assertNotEqual(
            first, self.run_shell("NETWORK_PREFIX=172.30.0; chain_runtime_config_dir")
        )
        self.assertNotEqual(
            first, self.run_shell("TARI_ONION=different.onion; chain_runtime_config_dir")
        )
        with (self.base / "two/build/tari/entrypoint.sh").open("a") as stream:
            stream.write("\ntrue\n")
        self.assertNotEqual(first, self.run_shell("chain_runtime_config_dir", "two"))

    def test_missing_source_and_tampered_runtime_fail(self):
        self.run_shell("prepare_chain_runtime_state; install_chain_runtime_config")
        target = Path(self.run_shell("chain_runtime_config_dir"))
        (target / "config.toml").write_text("tampered")
        self.run_shell("install_chain_runtime_config", success=False)
        (self.base / "two/build/tari/entrypoint.sh").unlink()
        self.run_shell("chain_runtime_config_dir", "two", success=False)

    def test_marker_migration_keeps_completion_and_old_copy(self):
        old = self.base / "one/data/clearnet-state"
        old.mkdir(parents=True)
        for chain in ("monero", "tari"):
            (old / f"{chain}.synced").write_text(f"{chain}-complete")
        self.run_shell("""
OLD_STATE="$PWD/data/clearnet-state"
docker() { printf '%s\\n' "$*" >>"$PWD/docker-calls"; }
prepare_chain_runtime_state
""")
        for chain in ("monero", "tari"):
            self.assertEqual(
                (self.shared / f"clearnet-state/{chain}.synced").read_bytes(),
                (old / f"{chain}.synced").read_bytes(),
            )
        self.assertIn("compose stop dashboard", (self.base / "one/docker-calls").read_text())
        self.assertEqual((self.shared / "clearnet-state").stat().st_mode & 0o7777, 0o1777)

    def test_runtime_paths_stay_out_of_operator_change_messages(self):
        for key in ("TARI_CONFIG_DIR", "LAN_GUARD_DIR"):
            result = self.run_shell(
                'source "$1/lib/pithead/39-describe-change.sh"; '
                "describe_notification_change() { return 1; }; "
                "describe_exposure_change() { return 1; }; "
                f"describe_change {key} /old /new"
            )
            self.assertEqual(result, "INFO")

    def test_lan_marker_unit_passes_paths_as_literal_arguments(self):
        output = self.run_shell(r"""
source "$1/lib/pithead/02b-lan-guard.sh"
source "$1/lib/pithead/02b-lan-guard-units.sh"
render_lan_guard_boot_unit /usr/sbin/iptables 'path with space;touch INJECTED;%H"$value/enforced' 18081
""")
        self.assertNotIn("/bin/sh -c", output)
        self.assertIn('ExecStartPost=/usr/bin/rm -f -- "path with space;touch INJECTED;%%H', output)
        self.assertIn('$$value/enforced"', output)
        self.assertFalse((self.base / "one/INJECTED").exists())

    def test_conflicting_state_and_symlink_are_refused(self):
        old = self.base / "one/data/clearnet-state"
        old.mkdir(parents=True)
        (old / "monero.synced").write_text("old")
        new = self.shared / "clearnet-state"
        new.mkdir()
        (new / "monero.synced").write_text("new")
        self.run_shell(
            'OLD_STATE="$PWD/data/clearnet-state"; prepare_chain_runtime_state', success=False
        )
        self.assertEqual((new / "monero.synced").read_text(), "new")
        new.rename(self.shared / "original")
        new.symlink_to(self.shared / "original")
        self.run_shell("prepare_chain_runtime_state", success=False)


if __name__ == "__main__":
    unittest.main()
