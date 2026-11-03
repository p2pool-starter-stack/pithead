# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
source "${BASH_SOURCE[0]%/*}/reset-restore-startup.sh"
# shellcheck source=tests/integration/lib/reset-restore-miner.sh
source "$(dirname "${BASH_SOURCE[0]}")/reset-restore-miner.sh" || exit $?

run_restore_dashboard_probe() {
    local before_config before_secrets before_tari after_config after_secrets after_tari probe_rc=0
    if ! before_config=$(rx 'sha256sum config.json') || [ -z "$before_config" ] ||
        ! before_secrets=$(upgrade_secret_fingerprints) || [ -z "$before_secrets" ] ||
        ! before_tari=$(env_on_box TARI_MODE) || [ -z "$before_tari" ]; then
        it_fail "restore probe captures the original Tari baseline (#3432)" "configuration, secrets or Tari mode unreadable"
        return 1
    fi
    if rx 'bash -s' --stdin <"$(dirname "${BASH_SOURCE[0]}")/restore-dashboard-guest.sh" 2>&1 |
        redact >"$OUT_DIR/restore-dashboard.log"; then
        it_pass "CLI restore refreshes dashboard configuration and running energy cost (#3432)"
    else
        it_fail "CLI restore refreshes dashboard configuration and running energy cost (#3432)" "see restore-dashboard.log"
        probe_rc=1
    fi
    if ! after_config=$(rx 'sha256sum config.json') || [ "$after_config" != "$before_config" ] ||
        ! after_secrets=$(upgrade_secret_fingerprints) || [ "$after_secrets" != "$before_secrets" ] ||
        ! after_tari=$(env_on_box TARI_MODE) || [ "$after_tari" != "$before_tari" ] ||
        ! wait_status_ok 240; then
        it_fail "restore probe returns the original healthy Tari baseline (#3432)" "configuration, secrets, Tari mode or readiness differs"
        return 1
    fi
    it_pass "restore probe returns the original healthy Tari baseline (#3432)"
    return "$probe_rc"
}

run_reset_restore() {
    RESET_RESTORE_STACK_INTACT=0
    local before_config before_secrets archive out rc after_config after_secrets
    local failures_before="$IT_FAIL" RR_MINER_NAMES='[]' RR_MINER_ENABLED=0 RR_MINER_LOCAL='' RR_MINER_BASELINE='[]'
    rr_miner_prepare || {
        it_fail "reset recovery captures online local miner and worker set" "enabled local miner or proxy worker census unavailable"
        return 1
    }
    it_step "encrypted backup → config-reset → restore without rendered configuration…"
    before_config=$(rx 'sha256sum config.json') && before_secrets=$(upgrade_secret_fingerprints) || {
        it_fail "reset recovery captures configuration and secrets" "snapshot unreadable"
        return 1
    }
    if ! rx "PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' $IT_PITHEAD backup -y" 2>&1 |
        redact >"$OUT_DIR/reset-restore.backup.log"; then
        it_fail "reset recovery creates encrypted backup" "backup failed; see reset-restore.backup.log"
        return 1
    fi
    archive=$(rx 'ls -t backups/pithead-backup-*.tar.gz.enc | head -n1') || archive=""
    if [ -z "$archive" ]; then
        it_fail "reset recovery creates encrypted backup" "no encrypted archive"
        return 1
    fi
    it_pass "reset recovery creates encrypted backup"

    # Hide all rendered/config state while real services run. The remote trap restores the files
    # even when a refusal check fails; no crafted .env or fake Compose command is used.
    local running_probe
    running_probe="set -e; stage=census; scratch=;
        trap 'rc=\$?; if [ -n \"\$scratch\" ]; then for f in config.json .env Caddyfile; do [ ! -e \"\$scratch/\$f\" ] || mv -- \"\$scratch/\$f\" \"\$f\"; done; rmdir -- \"\$scratch\"; fi; [ \"\$rc\" -eq 0 ] || printf \"reset-restore probe: failed at %s (exit %s)\\n\" \"\$stage\" \"\$rc\" >&2' EXIT
        before=\$(docker ps -q --filter label=com.docker.compose.project=pithead --filter status=running | wc -l);
        test \"\$before\" -gt 0;
        stage=scratch; scratch=\$(mktemp -d \"\${TMPDIR:-/tmp}/reset-restore.XXXXXX\");
        stage=hide; for f in config.json .env Caddyfile; do mv -- \"\$f\" \"\$scratch/\$f\"; done;
        stage=restore; set +e; output=\$($IT_PITHEAD restore -y $(quote_arg "$archive") </dev/null 2>&1); result=\$?; set -e;
        stage=refusal; {
            printf \"restore exit=%s running=%s first-line=%s\\n\" \"\$result\" \"\$(docker ps -q --filter label=com.docker.compose.project=pithead --filter status=running | wc -l)\" \"\$(printf %s \"\$output\" | head -n 1 | cut -c1-200)\";
            printf \"present after restore:\"; for f in config.json .env Caddyfile; do [ ! -e \"\$f\" ] || printf \" %s\" \"\$f\"; done; printf \"\\n\";
            [ \"\$result\" -eq 0 ] || [ -e config.json ] || [ -e .env ] || [ -e Caddyfile ] || [ \"\$(docker ps -q --filter label=com.docker.compose.project=pithead --filter status=running | wc -l)\" -ne \"\$before\" ] || printf \"stack intact\\n\";
        } >&2
        test \"\$result\" -ne 0 || { printf \"restore exited 0\\n\" >&2; exit 1; };
        case \"\$output\" in *'stack services are still active'*) ;; *)
            ce=\$(docker ps --all --quiet --filter label=com.docker.compose.project=pithead --filter status=running 2>&1 >/dev/null | head -n 2 | cut -c1-200);
            printf \"configless census stderr=[%s] pwd-base=%s\\n\" \"\$ce\" \"\$(basename \"\$PWD\")\" >&2;
            exit 1 ;; esac;
        stage=unchanged; test ! -e config.json; test ! -e .env; test ! -e Caddyfile"
    local probe_err
    if probe_err=$(rx "$running_probe" 2>&1 >/dev/null); then
        it_pass "restore refuses real running containers with all configuration missing"
    else
        probe_err=$(printf '%s' "$probe_err" | grep -v 'Permanently added' | redact | tail -n 10)
        # Restore refused (non-zero exit) and left every file absent: the stack is as it was, so
        # the phases after lifecycle can still run. Any other failure keeps the phase stopped.
        if grep -qx 'stack intact' <<<"$probe_err"; then
            # shellcheck disable=SC2034 # read by run_lifecycle
            RESET_RESTORE_STACK_INTACT=1
        fi
        # A Podman engine rejects status=restarting, so the configless census cannot finish (#3346).
        case "$probe_err" in *'first-line='*'could not verify that the stack is stopped'*) probe_err="restore could not take its configless census; see #3346. $probe_err" ;; esac
        it_fail "restore refuses real running containers with all configuration missing" "running census, refusal, or unchanged-file assertion failed: ${probe_err:-no output}"
        return 1
    fi

    local boot_before
    boot_before=$(rx 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
    if [ -z "$boot_before" ]; then
        it_fail "boot id is readable before config-reset" "the reboot wait needs a baseline"
        return 1
    fi
    rx "$IT_PITHEAD config-reset -y" 2>&1 |
        redact >"$OUT_DIR/reset-restore.reset.log"
    if grep -q 'Rebooting into first-boot' "$OUT_DIR/reset-restore.reset.log" && ! reset_restore_wait_reboot "$boot_before" 300; then
        it_fail "guest returns after the config-reset reboot" "no new boot reached the target within 300s"
        return 1
    fi
    if ! rx 'test ! -e config.json && test ! -e .env && test ! -e Caddyfile'; then
        it_fail "config-reset removes configuration before encrypted recovery" "reset failed or a rendered file remains; see reset-restore.reset.log"
        return 1
    fi
    it_pass "config-reset removes configuration before encrypted recovery"
    if reset_restore_shutdown_clean "$OUT_DIR/reset-restore.reset.log"; then
        it_pass "config-reset reports no failed shutdown before recovery"
    else
        it_fail "config-reset reports no failed shutdown before recovery" "failed-shutdown warning or unreadable reset log; see reset-restore.reset.log"
        return 1
    fi
    if reset_restore_wait_empty 60; then
        it_pass "config-reset leaves no pithead-project containers in any state"
    else
        it_fail "config-reset leaves no pithead-project containers in any state" "project residue or engine read failure before configless down"
        return 1
    fi
    if pithead down 2>&1 | redact >"$OUT_DIR/reset-restore.down.log"; then
        it_pass "pithead down succeeds after reset without Compose interpolation"
    else
        it_fail "pithead down succeeds after reset without Compose interpolation" "down failed; see reset-restore.down.log"
        return 1
    fi

    if grep -q 'Rebooting into first-boot' "$OUT_DIR/reset-restore.reset.log"; then
        if wait_for 300 5 "running wizard serving the setup page" rr_setup_page_ready; then
            it_pass "reset recovery starts with a running wizard serving the setup page"
        else
            it_fail "reset recovery starts with a running wizard serving the setup page" "trigger absent after 300s"
            return 1
        fi
    fi

    # A PTY makes Bash's read -p prompt observable. Empty input must reach the actual passphrase
    # request and refuse, rather than write anything. The successful leg then supplies a fixture
    # passphrase; no operator secret crosses the test transport or log.
    out=$(rx "printf '\\n' | env -u PITHEAD_BACKUP_PASSPHRASE script -q -e -c $(quote_arg "$IT_PITHEAD restore -y $(quote_arg "$archive")") /dev/null" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *"Backup passphrase:"* ]] && [[ "$out" == *"This archive is encrypted"* ]] &&
        rx 'test ! -e config.json && test ! -e .env && test ! -e Caddyfile'; then
        it_pass "encrypted restore after reset reaches the passphrase prompt"
    else
        it_fail "encrypted restore after reset reaches the passphrase prompt" "prompt or refusal missing, or configuration was promoted"
        printf '%s\n' "$out" | redact >"$OUT_DIR/reset-restore.prompt.log"
        return 1
    fi
    if ! rx "PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' $IT_PITHEAD restore -y $(quote_arg "$archive")" 2>&1 |
        redact >"$OUT_DIR/reset-restore.restore.log"; then
        it_fail "encrypted restore after config-reset starts the stack" "restore failed; see reset-restore logs"
        return 1
    fi
    rr_miner_state before-up || return 1
    if ! pithead up 2>&1 | redact >"$OUT_DIR/reset-restore.up.log"; then
        rr_miner_state failed-up || true
        it_fail "encrypted restore after config-reset starts the stack" "restore or up failed; see reset-restore logs"
        return 1
    fi
    rr_miner_recovered || return 1
    rr_web_ports_owned_by_dashboard "reset recovery" || return 1
    if wait_status_ok 600; then
        it_pass "stack healthy after encrypted restore following config-reset"
    else
        it_fail "stack healthy after encrypted restore following config-reset" "status did not recover"
        return 1
    fi
    if grep -q 'Rebooting into first-boot' "$OUT_DIR/reset-restore.reset.log"; then
        rr_restore_during_wizard_startup "$archive" || return 1
    fi
    after_config=$(rx 'sha256sum config.json') && after_secrets=$(upgrade_secret_fingerprints) || {
        it_fail "reset recovery reads restored configuration and secrets" "snapshot unreadable"
        return 1
    }
    assert_eq "reset recovery restores the backup configuration" "$after_config" "$before_config"
    assert_eq "reset recovery preserves backup secrets and identities" "$after_secrets" "$before_secrets"
    rx "rm -f -- $(quote_arg "$archive")" || {
        it_fail "reset recovery removes its encrypted fixture archive" "cleanup failed"
        return 1
    }
    [ "$IT_FAIL" -le "$failures_before" ]
}

# Wait until the target reports a boot id other than <before> (the appliance reboots on config-reset).
reset_restore_wait_reboot() { # <boot id before> <timeout seconds>
    local before="$1" deadline now boot_now
    deadline=$(($(date +%s) + $2))
    while now=$(date +%s) && [ "$now" -lt "$deadline" ]; do
        sleep 5
        boot_now=$(rx 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) || continue
        [ -n "$boot_now" ] && [ "$boot_now" != "$before" ] && return 0
    done
    return 1
}

reset_restore_shutdown_clean() { # <reset log>
    local scan_rc=0
    grep -Eq 'Stack shutdown failed|compose down failed' "$1" || scan_rc=$?
    [ "$scan_rc" -eq 1 ] # only a successful no-match is clean
}

reset_restore_wait_empty() { # <timeout seconds>; Docker also invokes Podman on the appliance
    local deadline=$(($(date +%s) + $1)) residue
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if residue=$(rx "docker ps --all --quiet --filter label=com.docker.compose.project=pithead" 2>/dev/null) && [ -z "$residue" ]; then
            return 0
        fi
        sleep 2
    done
    return 1
}
