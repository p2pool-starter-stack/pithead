#!/usr/bin/env bash
# Tier-4 appliance harness (#77 phase 2): boot the pithead-os image in KVM and prove the
# properties only real firmware + a real A/B updater can show — EFI boot, the first-boot wizard
# window, and the update/commit/rollback cycle that is the phase-2 exit criterion. This is the
# os-image sibling of tests/integration/run.sh; it needs a Linux host with KVM + libvirt + the
# built image, so it runs on the bench, not in CI.
#
#   tests/os/run.sh --image PATH [--keep] [--phase boot|update|install|provision|rig|media|fault|reset|all]
#
# Phases:
#   boot    flash the image to a scratch disk, boot it, assert EFI boot + firstboot wizard up
#   update  build a v2 bundle; install, boot the spare, auto-rollback uncommitted, commit, and
#           roll back off a committed version. Also asserts /data grew to the disk (#784), then
#           drives the same A/B cycle through the DASHBOARD OS-update action end-to-end (leg 4):
#           provision, check/download (resume proven), floor + bad-signature refusals, install,
#           the explicit reboot intent, the boot-gated commit, and the persisted verdict.
#   install boot the image as removable media beside a blank disk, run the disk installer, then
#           boot from the target and prove the copied system is COMPLETE (the /var overlay made
#           an incomplete copy easy to produce and invisible to every other phase). Then the
#           reinstall leg: /data must survive a second install over the same disk.
#   provision submit a config through the wizard's real HTTP flow and require the STACK to come
#           up — wizard accepted, setup ran, images pulled and verified, containers running,
#           dashboard served. This is the phase that catches an appliance whose engine cannot
#           actually run the product (it happened: pithead speaks docker, the image had only
#           podman, and every other phase was green).
#   rig     answer "RigForge" on the same page and prove the OTHER machine this image installs:
#           mines from the baked binary with no compile and no stack at all, and takes an A/B
#           update — install, uncommitted rollback, self-commit — exactly like a coordinator.
#   media   physical-presence config channel (#786 sub-issue D): a removable stick applied at boot
#           shows its exact diff on the console, counts down, applies, and consumes itself; pulling
#           it mid-countdown cancels the change. A minimal stick (#965) changes only what it names;
#           dashboard login, appliance defaults and node credentials survive, old login still works.
#   fault   power cuts mid-write and mid-commit, plus a corrupt bundle. A brick is disqualifying.
#   reset   factory-reset's ESP marker (the real `pithead factory-reset`) wipes /data and returns a
#           FRESH machine to the wizard; a corrupt /data superblock drives wedged-/data recovery.
#   all     every phase above, in that order — media, fault and reset included since #1064
#
# A failed assertion is recorded and the run continues, so one bench boot collects the whole
# battery rather than stopping at the first fault; the run exits non-zero if any assertion failed.
# --keep leaves the VM + disks for inspection.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=tests/os/hugepages-boot-verdict.sh
. "$SCRIPT_DIR/hugepages-boot-verdict.sh"
# shellcheck source=tests/os/failure-evidence.sh
. "$SCRIPT_DIR/failure-evidence.sh"
# shellcheck source=tests/os/kvm-preflight.sh
. "$SCRIPT_DIR/kvm-preflight.sh"
# shellcheck source=tests/os/journal-boot-verdict.sh
. "$SCRIPT_DIR/journal-boot-verdict.sh"
# shellcheck source=tests/os/restore-live-state-verdict.sh
. "$SCRIPT_DIR/restore-live-state-verdict.sh"
# shellcheck source=tests/os/reinstall-prefill-verdict.sh
. "$SCRIPT_DIR/reinstall-prefill-verdict.sh"
# shellcheck source=tests/os/data-floor-fallback-leg.sh
. "$SCRIPT_DIR/data-floor-fallback-leg.sh"
# shellcheck source=tests/os/aged-version.sh
. "$SCRIPT_DIR/aged-version.sh"
# shellcheck source=tests/os/provision-browser-submit.sh
. "$SCRIPT_DIR/provision-browser-submit.sh"
# shellcheck source=tests/os/reinstall-prefill-submit-leg.sh
. "$SCRIPT_DIR/reinstall-prefill-submit-leg.sh"
# shellcheck source=tests/os/setup-again-leg.sh
. "$SCRIPT_DIR/setup-again-leg.sh"
. "$SCRIPT_DIR/boot-label-serial-verdict.sh"
IMAGE=""
KEEP=0
PHASE="all"
VM="pithead-os-test"
DISK="/srv/code/bench-vm/pithead-os-test.img"
SERIAL="/tmp/pithead-os-serial.log"

while [ $# -gt 0 ]; do
    case "$1" in
    --image)
        IMAGE="$2"
        shift 2
        ;;
    --keep)
        KEEP=1
        shift
        ;;
    --phase)
        PHASE="$2"
        shift 2
        ;;
    -h | --help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown arg: $1" >&2
        exit 2
        ;;
    esac
done

PASS=0
FAIL=0

OS_RUN_SUITE=1
# shellcheck source=tests/os/lib/core.sh
source "$SCRIPT_DIR/lib/core.sh" || exit $?
# shellcheck source=tests/os/phases/boot.sh
source "$SCRIPT_DIR/phases/boot.sh" || exit $?
# shellcheck source=tests/os/phases/update.sh
source "$SCRIPT_DIR/phases/update.sh" || exit $?
# shellcheck source=tests/os/phases/update-dashboard.sh
source "$SCRIPT_DIR/phases/update-dashboard.sh" || exit $?
# shellcheck source=tests/os/phases/install.sh
source "$SCRIPT_DIR/phases/install.sh" || exit $?
# shellcheck source=tests/os/phases/provision.sh
source "$SCRIPT_DIR/phases/provision.sh" || exit $?
# shellcheck source=tests/os/phases/media.sh
source "$SCRIPT_DIR/phases/media.sh" || exit $?
# shellcheck source=tests/os/phases/rig.sh
source "$SCRIPT_DIR/phases/rig.sh" || exit $?
# shellcheck source=tests/os/phases/fault.sh
source "$SCRIPT_DIR/phases/fault.sh" || exit $?
# shellcheck source=tests/os/phases/reset.sh
source "$SCRIPT_DIR/phases/reset.sh" || exit $?
require_host
require_clean_bench
case "$PHASE" in
boot) phase_boot ;;
update) phase_update ;;
install) phase_install ;;
provision) phase_provision ;;
rig) phase_rig ;;
media) phase_media ;;
fault) phase_fault ;;
reset) phase_reset ;;
all)
    # ALL of them. This arm once ran five of eight while the release checklist told a maintainer
    # that step 1 covered everything — the mid-write and mid-commit power cuts, the corrupt-bundle
    # refusal, the factory reset, the wedged-/data recovery and the media channel omitted (#1064).
    phase_boot
    phase_update
    phase_install
    phase_provision
    phase_rig
    phase_media
    phase_fault
    phase_reset
    ;;
*)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

printf '\nos harness: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
