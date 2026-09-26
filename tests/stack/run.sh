#!/usr/bin/env bash
# Dependency-free test suite for pithead (no bats required).
# Mixes unit tests (sourcing pithead and calling its functions) with black-box CLI tests
# (running a sandboxed copy of pithead with docker/sudo stubbed out). Run: tests/stack/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/stack/test-harness-tooling.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-harness-tooling.sh" && domain_ran test-harness-tooling.sh "$_d0" "$?" || domain_ran test-harness-tooling.sh "$_d0" "$?"
# shellcheck source=tests/stack/doctor/test-doctor.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/doctor/test-doctor.sh" && domain_ran test-doctor.sh "$_d0" "$?" || domain_ran test-doctor.sh "$_d0" "$?"
# shellcheck source=tests/stack/doctor/test-doctor-onions.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/doctor/test-doctor-onions.sh" && domain_ran test-doctor-onions.sh "$_d0" "$?" || domain_ran test-doctor-onions.sh "$_d0" "$?"
# shellcheck source=tests/stack/control/test-control-upgrade.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-upgrade.sh" && domain_ran test-control-upgrade.sh "$_d0" "$?" || domain_ran test-control-upgrade.sh "$_d0" "$?"

# shellcheck source=tests/stack/control/test-control-upgrade-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-upgrade-lock.sh" && domain_ran test-control-upgrade-lock.sh "$_d0" "$?" || domain_ran test-control-upgrade-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/release/test-release-verify.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/release/test-release-verify.sh" && domain_ran test-release-verify.sh "$_d0" "$?" || domain_ran test-release-verify.sh "$_d0" "$?"
# shellcheck source=tests/stack/release/test-release-signing.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/release/test-release-signing.sh" && domain_ran test-release-signing.sh "$_d0" "$?" || domain_ran test-release-signing.sh "$_d0" "$?"

# shellcheck source=tests/stack/dashboard/test-dashboard.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/dashboard/test-dashboard.sh" && domain_ran test-dashboard.sh "$_d0" "$?" || domain_ran test-dashboard.sh "$_d0" "$?"
# shellcheck source=tests/stack/dashboard/test-dashboard-exposure-live.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/dashboard/test-dashboard-exposure-live.sh" && domain_ran test-dashboard-exposure-live.sh "$_d0" "$?" || domain_ran test-dashboard-exposure-live.sh "$_d0" "$?"

# shellcheck source=tests/stack/dashboard/test-dashboard-onion.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/dashboard/test-dashboard-onion.sh" && domain_ran test-dashboard-onion.sh "$_d0" "$?" || domain_ran test-dashboard-onion.sh "$_d0" "$?"

# Regression (#1330): test-dashboard-onion.sh passes alone; only a separate `bash`, not a subshell, proves it.
# shellcheck disable=SC1090,SC2015  # STACK/HERE paths are dynamic by design
bash -c '
    set -uo pipefail
    source "$1/lib.sh"
    source "$1/dashboard/test-dashboard-onion.sh" >/dev/null 2>&1
    [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
' _ "$HERE"
assert_rc "test-dashboard-onion.sh does not depend on run.sh's source order (#1330)" "$?" "0"

# shellcheck source=tests/stack/release/test-release.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/release/test-release.sh" && domain_ran test-release.sh "$_d0" "$?" || domain_ran test-release.sh "$_d0" "$?"
# shellcheck source=tests/stack/release/test-release-publish.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/release/test-release-publish.sh" && domain_ran test-release-publish.sh "$_d0" "$?" || domain_ran test-release-publish.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-unit-helpers.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-unit-helpers.sh" && domain_ran test-unit-helpers.sh "$_d0" "$?" || domain_ran test-unit-helpers.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-cli.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-cli.sh" && domain_ran test-cli.sh "$_d0" "$?" || domain_ran test-cli.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-config.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-config.sh" && domain_ran test-config.sh "$_d0" "$?" || domain_ran test-config.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-render-quadlet.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-render-quadlet.sh" && domain_ran test-render-quadlet.sh "$_d0" "$?" || domain_ran test-render-quadlet.sh "$_d0" "$?"

# shellcheck source=tests/stack/doctor/test-doctor-appliance.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/doctor/test-doctor-appliance.sh" && domain_ran test-doctor-appliance.sh "$_d0" "$?" || domain_ran test-doctor-appliance.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-setup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-setup.sh" && domain_ran test-appliance-setup.sh "$_d0" "$?" || domain_ran test-appliance-setup.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-restore.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-restore.sh" && domain_ran test-appliance-restore.sh "$_d0" "$?" || domain_ran test-appliance-restore.sh "$_d0" "$?"
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-restore-commit.sh" && domain_ran test-appliance-restore-commit.sh "$_d0" "$?" || domain_ran test-appliance-restore-commit.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-backup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-backup.sh" && domain_ran test-backup.sh "$_d0" "$?" || domain_ran test-backup.sh "$_d0" "$?"
_d0=$((PASS + FAIL)) && source "$HERE/test-backup-recovery.sh" && domain_ran test-backup-recovery.sh "$_d0" "$?" || domain_ran test-backup-recovery.sh "$_d0" "$?"
_d0=$((PASS + FAIL)) && source "$HERE/test-backup-stop-scope.sh" && domain_ran test-backup-stop-scope.sh "$_d0" "$?" || domain_ran test-backup-stop-scope.sh "$_d0" "$?"
_d0=$((PASS + FAIL)) && source "$HERE/test-cli-restore-hardening.sh" && domain_ran test-cli-restore-hardening.sh "$_d0" "$?" || domain_ran test-cli-restore-hardening.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-install-verify.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-install-verify.sh" && domain_ran test-install-verify.sh "$_d0" "$?" || domain_ran test-install-verify.sh "$_d0" "$?"
# shellcheck source=tests/stack/secrets/test-secrets.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/secrets/test-secrets.sh" && domain_ran test-secrets.sh "$_d0" "$?" || domain_ran test-secrets.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-rig-worker.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-rig-worker.sh" && domain_ran test-rig-worker.sh "$_d0" "$?" || domain_ran test-rig-worker.sh "$_d0" "$?"

# shellcheck source=tests/stack/control/test-control-status-vocabulary.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-status-vocabulary.sh" && domain_ran test-control-status-vocabulary.sh "$_d0" "$?" || domain_ran test-control-status-vocabulary.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-monero-tari.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-monero-tari.sh" && domain_ran test-monero-tari.sh "$_d0" "$?" || domain_ran test-monero-tari.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-recovery-address-gates.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-recovery-address-gates.sh" && domain_ran test-recovery-address-gates.sh "$_d0" "$?" || domain_ran test-recovery-address-gates.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-p2pool-tari-off.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-p2pool-tari-off.sh" && domain_ran test-p2pool-tari-off.sh "$_d0" "$?" || domain_ran test-p2pool-tari-off.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-tari-mode-off.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tari-mode-off.sh" && domain_ran test-tari-mode-off.sh "$_d0" "$?" || domain_ran test-tari-mode-off.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-tari-lmdb.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tari-lmdb.sh" && domain_ran test-tari-lmdb.sh "$_d0" "$?" || domain_ran test-tari-lmdb.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-xmrig-proxy-entrypoint.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-xmrig-proxy-entrypoint.sh" && domain_ran test-xmrig-proxy-entrypoint.sh "$_d0" "$?" || domain_ran test-xmrig-proxy-entrypoint.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-tari-fork-rewind.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tari-fork-rewind.sh" && domain_ran test-tari-fork-rewind.sh "$_d0" "$?" || domain_ran test-tari-fork-rewind.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-tor-network.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tor-network.sh" && domain_ran test-tor-network.sh "$_d0" "$?" || domain_ran test-tor-network.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-tor-egress-enforcement.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tor-egress-enforcement.sh" && domain_ran test-tor-egress-enforcement.sh "$_d0" "$?" || domain_ran test-tor-egress-enforcement.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-tor-egress-direction.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tor-egress-direction.sh" && domain_ran test-tor-egress-direction.sh "$_d0" "$?" || domain_ran test-tor-egress-direction.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-tor-egress-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tor-egress-boot.sh" && domain_ran test-tor-egress-boot.sh "$_d0" "$?" || domain_ran test-tor-egress-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/control/test-control-core.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-core.sh" && domain_ran test-control-core.sh "$_d0" "$?" || domain_ran test-control-core.sh "$_d0" "$?"

# shellcheck source=tests/stack/secrets/test-secrets-masking.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/secrets/test-secrets-masking.sh" && domain_ran test-secrets-masking.sh "$_d0" "$?" || domain_ran test-secrets-masking.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-confirm-approval.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-confirm-approval.sh" && domain_ran test-confirm-approval.sh "$_d0" "$?" || domain_ran test-confirm-approval.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-data-management.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-data-management.sh" && domain_ran test-data-management.sh "$_d0" "$?" || domain_ran test-data-management.sh "$_d0" "$?"

# The approval gate (#33): default-deny, workers.list[]'s add-only exception (#893), the #122 SSRF
# floor; own sandbox (#1105 R13). The tier3 stanza is POSITION-LOCKED: gate_try()/$UUID5 (2026-09-13 perimeter audit).
# shellcheck source=tests/stack/control/test-control-add-only-ssrf.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-add-only-ssrf.sh" && domain_ran test-control-add-only-ssrf.sh "$_d0" "$?" || domain_ran test-control-add-only-ssrf.sh "$_d0" "$?"
# shellcheck source=tests/stack/control/test-control-perimeter-tier3.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-perimeter-tier3.sh" && domain_ran test-control-perimeter-tier3.sh "$_d0" "$?" || domain_ran test-control-perimeter-tier3.sh "$_d0" "$?"
# shellcheck source=tests/stack/control/test-control-secret-and-dial-guards.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-secret-and-dial-guards.sh" && domain_ran test-control-secret-and-dial-guards.sh "$_d0" "$?" || domain_ran test-control-secret-and-dial-guards.sh "$_d0" "$?"

# shellcheck source=tests/stack/control/test-control-editable-allowlist.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-editable-allowlist.sh" && domain_ran test-control-editable-allowlist.sh "$_d0" "$?" || domain_ran test-control-editable-allowlist.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-worker-config.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-worker-config.sh" && domain_ran test-worker-config.sh "$_d0" "$?" || domain_ran test-worker-config.sh "$_d0" "$?"

echo "== black-box: notification secrets masked in the prefill copy (#848) =="
# The ntfy topic URL + token are bearer credentials, and each notifications.webhooks[] entry IS a
# bearer URL (query strings carry tokens). All must be sentineled in the world-readable masked copy
# — one LEAK- marker across every set secret proves the whole set at once; a blank webhook entry and
# the non-secret notifications.tor flag must survive so the editor can still render the form.
jq '.notifications = {
    webhooks: ["https://hooks.example/LEAK-hookA", "", "https://hooks.example/LEAK-hookB"],
    ntfy: {url: "https://ntfy.example/LEAK-ntfyurl", token: "LEAK-ntfytoken"},
    tor: true}' "$C/config.json" >"$C/config.json.tmp" && mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
assert_eq "ntfy url masked to the sentinel" "$(jq -c '.notifications.ntfy.url' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "ntfy token masked to the sentinel" "$(jq -c '.notifications.ntfy.token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "first webhook entry masked to the sentinel" "$(jq -c '.notifications.webhooks[0]' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "third webhook entry masked to the sentinel" "$(jq -c '.notifications.webhooks[2]' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "a blank webhook entry stays blank in the masked copy" "$(jq -r '.notifications.webhooks[1]' "$MASKED" 2>/dev/null)" ""
assert_eq "the non-secret notifications.tor flag survives" "$(jq -r '.notifications.tor' "$MASKED" 2>/dev/null)" "true"
case "$(cat "$MASKED")" in
*LEAK-*) bad "masked copy holds no notification secret" "a notification secret leaked into $MASKED" ;;
*) ok "masked copy holds no notification secret" ;;
esac

# shellcheck source=tests/stack/test-spool-audit.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-spool-audit.sh" && domain_ran test-spool-audit.sh "$_d0" "$?" || domain_ran test-spool-audit.sh "$_d0" "$?"
# shellcheck source=tests/stack/control/test-control-deploy.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-deploy.sh" && domain_ran test-control-deploy.sh "$_d0" "$?" || domain_ran test-control-deploy.sh "$_d0" "$?"
# shellcheck source=tests/stack/control/test-control-deploy-layout.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-deploy-layout.sh" && domain_ran test-control-deploy-layout.sh "$_d0" "$?" || domain_ran test-control-deploy-layout.sh "$_d0" "$?"
# shellcheck source=tests/stack/control/test-control-lifecycle-verbs.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-lifecycle-verbs.sh" && domain_ran test-control-lifecycle-verbs.sh "$_d0" "$?" || domain_ran test-control-lifecycle-verbs.sh "$_d0" "$?"

# shellcheck source=tests/stack/control/test-control-backup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-backup.sh" && domain_ran test-control-backup.sh "$_d0" "$?" || domain_ran test-control-backup.sh "$_d0" "$?"

# shellcheck source=tests/stack/doctor/test-doctor-exposure.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/doctor/test-doctor-exposure.sh" && domain_ran test-doctor-exposure.sh "$_d0" "$?" || domain_ran test-doctor-exposure.sh "$_d0" "$?"

# shellcheck source=tests/stack/control/test-control-diagnostics.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-diagnostics.sh" && domain_ran test-control-diagnostics.sh "$_d0" "$?" || domain_ran test-control-diagnostics.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-wizard-setup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-wizard-setup.sh" && domain_ran test-wizard-setup.sh "$_d0" "$?" || domain_ran test-wizard-setup.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-wizard-tari.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-wizard-tari.sh" && domain_ran test-wizard-tari.sh "$_d0" "$?" || domain_ran test-wizard-tari.sh "$_d0" "$?"
# shellcheck source=tests/stack/control/test-control-provisioning.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/control/test-control-provisioning.sh" && domain_ran test-control-provisioning.sh "$_d0" "$?" || domain_ran test-control-provisioning.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-identity.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-identity.sh" && domain_ran test-appliance-identity.sh "$_d0" "$?" || domain_ran test-appliance-identity.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-hostname.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-hostname.sh" && domain_ran test-appliance-hostname.sh "$_d0" "$?" || domain_ran test-appliance-hostname.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-defaults.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-defaults.sh" && domain_ran test-appliance-defaults.sh "$_d0" "$?" || domain_ran test-appliance-defaults.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-install.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-install.sh" && domain_ran test-appliance-install.sh "$_d0" "$?" || domain_ran test-appliance-install.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-install-restore.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-install-restore.sh" && domain_ran test-appliance-install-restore.sh "$_d0" "$?" || domain_ran test-appliance-install-restore.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-rig-miner.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-rig-miner.sh" && domain_ran test-appliance-rig-miner.sh "$_d0" "$?" || domain_ran test-appliance-rig-miner.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-rig-token-landing.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-rig-token-landing.sh" && domain_ran test-appliance-rig-token-landing.sh "$_d0" "$?" || domain_ran test-appliance-rig-token-landing.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-wizard-spool.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-wizard-spool.sh" && domain_ran test-appliance-wizard-spool.sh "$_d0" "$?" || domain_ran test-appliance-wizard-spool.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-setup-again.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-setup-again.sh" && domain_ran test-appliance-setup-again.sh "$_d0" "$?" || domain_ran test-appliance-setup-again.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-boot.sh" && domain_ran test-appliance-boot.sh "$_d0" "$?" || domain_ran test-appliance-boot.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-boot-remint.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-boot-remint.sh" && domain_ran test-appliance-boot-remint.sh "$_d0" "$?" || domain_ran test-appliance-boot-remint.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-boot-stack-health.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-boot-stack-health.sh" && domain_ran test-appliance-boot-stack-health.sh "$_d0" "$?" || domain_ran test-appliance-boot-stack-health.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-cert-advisory.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-cert-advisory.sh" && domain_ran test-appliance-cert-advisory.sh "$_d0" "$?" || domain_ran test-appliance-cert-advisory.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-boot-release.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-boot-release.sh" && domain_ran test-appliance-boot-release.sh "$_d0" "$?" || domain_ran test-appliance-boot-release.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-build-compose-source.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-build-compose-source.sh" && domain_ran test-appliance-build-compose-source.sh "$_d0" "$?" || domain_ran test-appliance-build-compose-source.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-os-update.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-os-update.sh" && domain_ran test-appliance-os-update.sh "$_d0" "$?" || domain_ran test-appliance-os-update.sh "$_d0" "$?"
source "$HERE/appliance/test-appliance-boot-labels.sh"
# shellcheck source=tests/stack/appliance/test-appliance-os-update-verbs.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-os-update-verbs.sh" && domain_ran test-appliance-os-update-verbs.sh "$_d0" "$?" || domain_ran test-appliance-os-update-verbs.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-data-floor.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-data-floor.sh" && domain_ran test-appliance-data-floor.sh "$_d0" "$?" || domain_ran test-appliance-data-floor.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-os-update-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-os-update-lock.sh" && domain_ran test-appliance-os-update-lock.sh "$_d0" "$?" || domain_ran test-appliance-os-update-lock.sh "$_d0" "$?"
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-os-update-reboot.sh" && domain_ran test-appliance-os-update-reboot.sh "$_d0" "$?" || domain_ran test-appliance-os-update-reboot.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-kernel-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-kernel-boot.sh" && domain_ran test-appliance-kernel-boot.sh "$_d0" "$?" || domain_ran test-appliance-kernel-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-reset.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-reset.sh" && domain_ran test-appliance-reset.sh "$_d0" "$?" || domain_ran test-appliance-reset.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-reset-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-reset-lock.sh" && domain_ran test-appliance-reset-lock.sh "$_d0" "$?" || domain_ran test-appliance-reset-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-caddyfile-optional-env.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-caddyfile-optional-env.sh" && domain_ran test-appliance-caddyfile-optional-env.sh "$_d0" "$?" || domain_ran test-appliance-caddyfile-optional-env.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-rotate-secrets-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-rotate-secrets-lock.sh" && domain_ran test-appliance-rotate-secrets-lock.sh "$_d0" "$?" || domain_ran test-appliance-rotate-secrets-lock.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-firstboot-install-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-firstboot-install-lock.sh" && domain_ran test-appliance-firstboot-install-lock.sh "$_d0" "$?" || domain_ran test-appliance-firstboot-install-lock.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-readonly-verbs-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-readonly-verbs-lock.sh" && domain_ran test-readonly-verbs-lock.sh "$_d0" "$?" || domain_ran test-readonly-verbs-lock.sh "$_d0" "$?"
_d0=$((PASS + FAIL)) && source "$HERE/test-cli-verb-ledger-lock.sh" && domain_ran test-cli-verb-ledger-lock.sh "$_d0" "$?" || domain_ran test-cli-verb-ledger-lock.sh "$_d0" "$?"
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-identity-boot.sh" && domain_ran test-appliance-identity-boot.sh "$_d0" "$?" || domain_ran test-appliance-identity-boot.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-boot-verdicts.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-boot-verdicts.sh" && domain_ran test-appliance-boot-verdicts.sh "$_d0" "$?" || domain_ran test-appliance-boot-verdicts.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-machine-id-journal.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-machine-id-journal.sh" && domain_ran test-appliance-machine-id-journal.sh "$_d0" "$?" || domain_ran test-appliance-machine-id-journal.sh "$_d0" "$?"

# shellcheck source=tests/stack/appliance/test-appliance-media.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-media.sh" && domain_ran test-appliance-media.sh "$_d0" "$?" || domain_ran test-appliance-media.sh "$_d0" "$?"
# shellcheck source=tests/stack/appliance/test-appliance-media-console.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/appliance/test-appliance-media-console.sh" && domain_ran test-appliance-media-console.sh "$_d0" "$?" || domain_ran test-appliance-media-console.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-rauc-loop-wait.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-rauc-loop-wait.sh" && domain_ran test-rauc-loop-wait.sh "$_d0" "$?" || domain_ran test-rauc-loop-wait.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-lifecycle.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-lifecycle.sh" && domain_ran test-lifecycle.sh "$_d0" "$?" || domain_ran test-lifecycle.sh "$_d0" "$?"

# shellcheck source=tests/stack/doctor/test-doctor-surface.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/doctor/test-doctor-surface.sh" && domain_ran test-doctor-surface.sh "$_d0" "$?" || domain_ran test-doctor-surface.sh "$_d0" "$?"
# shellcheck source=tests/stack/doctor/test-doctor-memory.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/doctor/test-doctor-memory.sh" && domain_ran test-doctor-memory.sh "$_d0" "$?" || domain_ran test-doctor-memory.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-lock-reinvoke-wiring.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-lock-reinvoke-wiring.sh" && domain_ran test-lock-reinvoke-wiring.sh "$_d0" "$?" || domain_ran test-lock-reinvoke-wiring.sh "$_d0" "$?"

echo ""
printf 'pithead tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
