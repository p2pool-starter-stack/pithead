import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCES = (
    "02a-tor-egress-boot.sh",
    "02c-tor-egress-check.sh",
    "02b-lan-guard-units.sh",
    "08-uninstall-firstboot.sh",
)
GROUPS = {
    "remove_tor_egress_boot_unit": ("pithead-egress.service",),
    "remove_egress_check_units": (
        "pithead-egress.timer",
        "pithead-egress-check.service",
    ),
    "remove_lan_guard_check_units": (
        "pithead-lan.timer",
        "pithead-lan-check.service",
    ),
    "remove_lan_guard_boot_unit": (
        "pithead-lan-hold.service",
        "pithead-lan-guard.service",
    ),
}


class SystemdRemovalTest(unittest.TestCase):
    def drive(self, action, failure="", foreign=False):
        with tempfile.TemporaryDirectory() as directory:
            box = Path(directory)
            units = box / "units"
            units.mkdir()
            names = GROUPS.get(action, sum(GROUPS.values(), ()))
            for name in names:
                (units / name).touch()
                (box / (name + ".state")).write_text(
                    "failed" if "check.service" in name else "active exited"
                )
            (box / "unrelated.service.state").write_text("failed")
            (box / ".env").write_text("CONTROL_DIR=" + str(box / "data/control"))
            script = """
set -uo pipefail
for slice in $SOURCES; do source "$ROOT/lib/pithead/$slice"; done
TOR_EGRESS_BOOT_UNIT=pithead-egress.service
EGRESS_CHECK_TIMER=pithead-egress.timer
EGRESS_CHECK_SERVICE=pithead-egress-check.service
LAN_GUARD_CHECK_TIMER=pithead-lan.timer
LAN_GUARD_CHECK_SERVICE=pithead-lan-check.service
LAN_GUARD_BOOT_UNIT=pithead-lan-guard.service
LAN_GUARD_HOLD_UNIT=pithead-lan-hold.service
control_unit_dir() { echo "$PWD/units"; }
control_units_owner_dir() { if [ "$FOREIGN" = 1 ]; then echo /other; else pwd -P; fi; }
warn() { echo "$*"; }
log() { echo "$*"; }
error() { echo "$*"; exit 1; }
sudo() { "$@"; }
systemctl() {
    printf '%s\\n' "$*" >>calls
    [ "$1" != "$FAILURE" ] || return 1
    local verb="$1" unit
    shift
    case "$verb" in
    stop)
        for unit in "$@"; do
            [ "$(cat "$unit.state" 2>/dev/null)" = failed ] || echo inactive >"$unit.state"
        done ;;
    reset-failed)
        for unit in "$@"; do echo inactive >"$unit.state"; done ;;
    daemon-reload)
        for unit in *.state; do
            if [ ! -e "units/${unit%.state}" ] && [ "$(cat "$unit")" = inactive ]; then rm "$unit"; fi
        done ;;
    list-units)
        for unit in "$@"; do
            case "$unit" in --*) continue ;; esac
            [ ! -e "$unit.state" ] || printf '%s not-found %s\\n' "$unit" "$(cat "$unit.state")"
        done
        [ "$FAILURE" != lingering ] || echo "pithead-egress.service not-found active exited" ;;
    esac
    return 0
}
superseded_by_live_install() { return 1; }
detect_os() { :; }
env_get_file() { :; }
compose_project_name() { echo pithead; }
mutation_lock_acquire() { :; }
mutation_lock_release() { :; }
remove_tor_egress_firewall() { :; }
lan_guard_teardown() { :; }
docker() { :; }
provision_control_runner() { :; }
is_versioned_install_dir() { return 1; }
"$ACTION" ${UNINSTALL_ARGS:-}
"""
            result = subprocess.run(  # noqa: S603
                ["/usr/bin/env", "bash", "-c", script],
                cwd=box,
                env={
                    **os.environ,
                    "ROOT": str(ROOT),
                    "SOURCES": " ".join(SOURCES),
                    "ACTION": action,
                    "UNINSTALL_ARGS": "-y" if action == "stack_uninstall" else "",
                    "FAILURE": failure,
                    "FOREIGN": str(int(foreign)),
                },
                capture_output=True,
                text=True,
                timeout=15,
            )
            remaining = sorted(p.name for p in box.glob("*.state"))
            return (
                result,
                remaining,
                (box / "calls").read_text() if (box / "calls").exists() else "",
            )

    def test_active_and_failed_records_are_removed(self):
        for action in (*GROUPS, "stack_uninstall"):
            with self.subTest(action=action):
                result, remaining, calls = self.drive(action)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(remaining, ["unrelated.service.state"])
                self.assertNotIn("reset-failed unrelated", calls)
                names = GROUPS.get(action, sum(GROUPS.values(), ()))
                for name in names:
                    self.assertIn("stop " + name, calls)
                    self.assertIn("reset-failed " + name, calls)
                self.assertIn("list-units --all --plain --no-legend", calls)

    def test_command_failures_cannot_report_removal(self):
        for action in (*GROUPS, "stack_uninstall"):
            for failure in (
                "disable",
                "stop",
                "reset-failed",
                "daemon-reload",
                "list-units",
                "lingering",
            ):
                with self.subTest(action=action, failure=failure):
                    result, remaining, _ = self.drive(action, failure)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertNotIn("Uninstalled.", result.stdout)
                    self.assertIn("unrelated.service.state", remaining)

    def test_foreign_check_units_are_untouched(self):
        for action in ("remove_egress_check_units", "remove_lan_guard_check_units"):
            with self.subTest(action=action):
                result, remaining, calls = self.drive(action, foreign=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(len(remaining), 3)
                self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
