#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=tests/os/hugepages-boot-verdict.sh
. "$SCRIPT_DIR/hugepages-boot-verdict.sh"
# shellcheck source=tests/os/secure-boot-boot-verdict.sh
. "$SCRIPT_DIR/secure-boot-boot-verdict.sh"
# shellcheck source=tests/os/failure-evidence.sh
. "$SCRIPT_DIR/failure-evidence.sh"
# shellcheck source=tests/os/staging-failure-evidence.sh
. "$SCRIPT_DIR/staging-failure-evidence.sh"
# shellcheck source=tests/os/tor-health-evidence.sh
. "$SCRIPT_DIR/tor-health-evidence.sh"
# shellcheck source=tests/os/zero-container-evidence.sh
. "$SCRIPT_DIR/zero-container-evidence.sh"
# shellcheck source=tests/os/bundle-build-evidence.sh
. "$SCRIPT_DIR/bundle-build-evidence.sh"
. "$SCRIPT_DIR/package-appliance-verdict.sh"
. "$SCRIPT_DIR/release-appliance-verdict.sh"
# shellcheck source=tests/os/kvm-preflight.sh
. "$SCRIPT_DIR/kvm-preflight.sh"
# shellcheck source=tests/os/journal-boot-verdict.sh
. "$SCRIPT_DIR/journal-boot-verdict.sh"
# shellcheck source=tests/os/restore-live-state-verdict.sh
. "$SCRIPT_DIR/restore-live-state-verdict.sh"
# shellcheck source=tests/os/reinstall-prefill-verdict.sh
. "$SCRIPT_DIR/reinstall-prefill-verdict.sh"
# shellcheck source=tests/os/provisioning-settled.sh
. "$SCRIPT_DIR/provisioning-settled.sh"
# shellcheck source=tests/os/data-floor-fallback-leg.sh
. "$SCRIPT_DIR/data-floor-fallback-leg.sh"
# shellcheck source=tests/os/aged-version.sh
. "$SCRIPT_DIR/aged-version.sh"
# shellcheck source=tests/os/provision-browser-submit.sh
. "$SCRIPT_DIR/provision-browser-submit.sh"
. "$SCRIPT_DIR/image-upgrade-certificate-leg.sh"
# shellcheck source=tests/os/appliance-hostname-leg.sh
. "$SCRIPT_DIR/appliance-hostname-leg.sh"
# shellcheck source=tests/os/appliance-diagnostics-leg.sh
. "$SCRIPT_DIR/appliance-diagnostics-leg.sh"
# shellcheck source=tests/os/appliance-config-approval-leg.sh
. "$SCRIPT_DIR/appliance-config-approval-leg.sh"
# shellcheck source=tests/os/appliance-earnings-leg.sh
. "$SCRIPT_DIR/appliance-earnings-leg.sh"
# shellcheck source=tests/os/appliance-tari-mode-leg.sh
. "$SCRIPT_DIR/appliance-tari-mode-leg.sh"
# shellcheck source=tests/os/caddy-failure-evidence.sh
. "$SCRIPT_DIR/caddy-failure-evidence.sh"
# shellcheck source=tests/os/appliance-egress-leg.sh
. "$SCRIPT_DIR/appliance-egress-leg.sh"
# shellcheck source=tests/os/appliance-xvb-routing-leg.sh
. "$SCRIPT_DIR/appliance-xvb-routing-leg.sh"
# shellcheck source=tests/os/appliance-address-watch-leg.sh
. "$SCRIPT_DIR/appliance-address-watch-leg.sh"
# shellcheck source=tests/os/appliance-dashboard-exposure-leg.sh
. "$SCRIPT_DIR/appliance-dashboard-exposure-leg.sh"
# shellcheck source=tests/os/appliance-lan-guard-leg.sh
. "$SCRIPT_DIR/appliance-lan-guard-leg.sh"
# shellcheck source=tests/os/appliance-monero-rpc-leg.sh
. "$SCRIPT_DIR/appliance-monero-rpc-leg.sh"
# shellcheck source=tests/os/appliance-tari-wallet-leg.sh
. "$SCRIPT_DIR/appliance-tari-wallet-leg.sh"
# shellcheck source=tests/os/appliance-chain-fault-leg.sh
. "$SCRIPT_DIR/appliance-chain-fault-leg.sh"
# shellcheck source=tests/integration/lib/mergemine-probe.sh
. "$SCRIPT_DIR/../integration/lib/mergemine-probe.sh"
# ONLY the it_skip_* vocabulary is wanted from this file (#2064): the missing/by-design/covered
# classes the integration summary already prints (#1083/#1444), reused rather than re-invented so
# the two tier-4 summaries read the same way. Its other export, assert_mining_state, is NOT for
# this harness — it calls assert_num_ge/assert_num_gt, which live in tests/integration/lib.sh and
# are deliberately not sourced here. it_warn/it_err, which the it_skip_* helpers call, are
# lib/core.sh's.
# shellcheck source=tests/integration/lib/skip-accounting.sh
. "$SCRIPT_DIR/../integration/lib/skip-accounting.sh"
# shellcheck source=tests/os/reinstall-prefill-submit-leg.sh
. "$SCRIPT_DIR/reinstall-prefill-submit-leg.sh"
# shellcheck source=tests/os/setup-failure-recovery-leg.sh
. "$SCRIPT_DIR/setup-failure-recovery-leg.sh"
# shellcheck source=tests/os/control-runner-recovery-leg.sh
. "$SCRIPT_DIR/control-runner-recovery-leg.sh"
# shellcheck source=tests/os/setup-again-leg.sh
. "$SCRIPT_DIR/setup-again-leg.sh"
# shellcheck source=tests/os/rig-config-meta-wait.sh
. "$SCRIPT_DIR/rig-config-meta-wait.sh"
# shellcheck source=tests/os/rig-control-off-leg.sh
. "$SCRIPT_DIR/rig-control-off-leg.sh"
# shellcheck source=tests/os/rig-share-leg.sh
. "$SCRIPT_DIR/rig-share-leg.sh"
. "$SCRIPT_DIR/boot-label-serial-verdict.sh"
# shellcheck source=tests/os/fault-boot-verdict.sh
. "$SCRIPT_DIR/fault-boot-verdict.sh"
# shellcheck source=tests/os/m10-height-verdict.sh
. "$SCRIPT_DIR/m10-height-verdict.sh"
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
        printf '%s\n' 'Usage: tests/os/run.sh --image PATH [--keep] [--phase boot|update|install|provision|setup-defaults|rig|rigmedia|media|fault|reset|image-upgrade|crossupdate|stack|tor-heal|all]'
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
# shellcheck source=tests/os/lib/identity.sh
source "$SCRIPT_DIR/lib/identity.sh" || exit $?
# shellcheck source=tests/os/wizard-redirect-leg.sh
source "$SCRIPT_DIR/wizard-redirect-leg.sh" || exit $?
source "$SCRIPT_DIR/wizard-identity-leg.sh" || exit $?
# shellcheck source=tests/os/phases/boot.sh
source "$SCRIPT_DIR/phases/boot.sh" || exit $?
# shellcheck source=tests/os/phases/update-spare-slot.sh
source "$SCRIPT_DIR/phases/update-spare-slot.sh" || exit $?
# shellcheck source=tests/os/phases/update.sh
source "$SCRIPT_DIR/phases/update.sh" || exit $?
# shellcheck source=tests/os/phases/update-dashboard.sh
source "$SCRIPT_DIR/phases/update-dashboard.sh" || exit $?
# shellcheck source=tests/os/phases/update-healthgate-leg.sh
source "$SCRIPT_DIR/phases/update-healthgate-leg.sh" || exit $?
# shellcheck source=tests/os/phases/update-rollback-leg.sh
source "$SCRIPT_DIR/phases/update-rollback-leg.sh" || exit $?
# shellcheck source=tests/os/phases/install.sh
source "$SCRIPT_DIR/phases/install.sh" || exit $?
# shellcheck source=tests/os/phases/provision.sh
source "$SCRIPT_DIR/phases/provision.sh" || exit $?
# shellcheck source=tests/os/phases/setup-defaults.sh
source "$SCRIPT_DIR/phases/setup-defaults.sh" || exit $?
# shellcheck source=tests/os/phases/media.sh
source "$SCRIPT_DIR/phases/media.sh" || exit $?
# shellcheck source=tests/os/phases/rig.sh
source "$SCRIPT_DIR/phases/rig.sh" || exit $?
# shellcheck source=tests/os/phases/rigmedia.sh
source "$SCRIPT_DIR/phases/rigmedia.sh" || exit $?
# shellcheck source=tests/os/phases/fault.sh
source "$SCRIPT_DIR/phases/fault.sh" || exit $?
# shellcheck source=tests/os/phases/reset.sh
source "$SCRIPT_DIR/phases/reset.sh" || exit $?
# shellcheck source=tests/os/phases/image-upgrade.sh
source "$SCRIPT_DIR/phases/image-upgrade.sh" || exit $?
# shellcheck source=tests/os/phases/crossupdate.sh
source "$SCRIPT_DIR/phases/crossupdate.sh" || exit $?
# shellcheck source=tests/os/phases/stack.sh
source "$SCRIPT_DIR/phases/stack.sh" || exit $?
# shellcheck source=tests/os/phases/tor-heal.sh
source "$SCRIPT_DIR/phases/tor-heal.sh" || exit $?
require_host
require_clean_bench
if [ "$PHASE" = "boot" ] || [ "$PHASE" = "all" ]; then
    PITHEAD_EXPECT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)" \
        tests/os/verify-image.sh "$IMAGE" --test || exit $?
fi

# #2356: a phase can return having recorded nothing at all — no ok/bad, no it_skip_* call of its
# own (the shape a missing bench input produces when the phase's own code only prints and returns
# rather than going through the counted skip vocabulary). Left alone, that phase is invisible to
# PASS/FAIL and to every skip bucket, and the run reads as a clean, empty pass. This wrapper is the
# one place every phase is invoked from, so it is the one place that can catch that for ALL of them
# without each phase file having to get its own accounting right: if a phase call adds nothing to
# PASS, FAIL or any skip bucket, the wrapper itself records the phase as a `missing` skip — an
# absent input is exactly what "an input would have run it" means.
_run_phase() { # <phase-name> <phase-function>
    local before=$((PASS + FAIL + IT_SKIPPED + IT_SKIPPED_PHASES + IT_SKIPPED_LEGS))
    "$2"
    local after=$((PASS + FAIL + IT_SKIPPED + IT_SKIPPED_PHASES + IT_SKIPPED_LEGS))
    [ "$after" -ne "$before" ] ||
        it_skip_phase "$1" "produced no passed, failed or skipped row — a required input was likely absent" missing
}
case "$PHASE" in
boot) _run_phase boot phase_boot ;;
update) _run_phase update phase_update ;;
install) _run_phase install phase_install ;;
provision) _run_phase provision phase_provision ;;
setup-defaults) _run_phase setup-defaults phase_setup_defaults ;;
rig) _run_phase rig phase_rig ;;
rigmedia) _run_phase rigmedia phase_rigmedia ;;
media) _run_phase media phase_media ;;
fault) _run_phase fault phase_fault ;;
reset) _run_phase reset phase_reset ;;
image-upgrade) _run_phase image-upgrade phase_image_upgrade ;;
crossupdate) _run_phase crossupdate phase_crossupdate ;;
stack) _run_phase stack phase_stack ;;
tor-heal) _run_phase tor-heal phase_tor_heal ;;
all)
    # ALL of them. This arm once ran five of eight while the release checklist told a maintainer
    # that step 1 covered everything — the mid-write and mid-commit power cuts, the corrupt-bundle
    # refusal, the factory reset, the wedged-/data recovery and the media channel omitted (#1064).
    _run_phase boot phase_boot
    _run_phase update phase_update
    _run_phase install phase_install
    _run_phase provision phase_provision
    _run_phase setup-defaults phase_setup_defaults
    _run_phase rig phase_rig
    _run_phase rigmedia phase_rigmedia
    _run_phase media phase_media
    _run_phase fault phase_fault
    _run_phase reset phase_reset
    _run_phase image-upgrade phase_image_upgrade
    _run_phase stack phase_stack
    ;;
*)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

printf '\nos harness: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n' "$PASS" "$FAIL"
# The three buckets stay SEPARATE, and the breakdown under them is worded exactly as
# tests/integration/lib/run-safety.sh's summary() words it (#1083/#1365), so the two tier-4
# summaries compare line for line rather than nearly. Losing a whole phase is not the same size of
# hole as losing one leg, which is why one summed number was the wrong shape. Only "missing" is a
# gap; see skip-accounting.sh for what each class means.
printf 'skipped: %d scenarios, %d phases, %d legs\n' \
    "$IT_SKIPPED" "$IT_SKIPPED_PHASES" "$IT_SKIPPED_LEGS"
printf "  of which: %d missing (an input would have run it), %d by-design (this run's mode excludes it), %d covered elsewhere\n" \
    "$IT_SKIPPED_MISSING" "$IT_SKIPPED_BY_DESIGN" "$IT_SKIPPED_COVERED"
if [ -n "$IT_SKIPPED_NAMES" ]; then
    echo "did NOT run:" >&2
    echo -e "$IT_SKIPPED_NAMES" >&2
fi
# #2356: 0 passed and 0 failed is not a clean run, it is every requested phase skipping — the
# vacuous-success shape a bench job hit when the fleet's node provider left required inputs unset.
# A run that executed at least one row (a pass, a fail) keeps today's behaviour below; only the
# all-skipped case is new.
if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
    echo "no requested phase ran (--phase $PHASE): every row was skipped" >&2
    exit 1
fi
[ "$FAIL" -eq 0 ]
