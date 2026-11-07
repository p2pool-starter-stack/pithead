# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
source "${BASH_SOURCE[0]%/*}/reset-restore-startup.sh"

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
    local scratch original_config original_secrets after_config after_secrets saved_umask rc=0 mutated=0 verified=1
    saved_umask=$(umask)
    umask 077
    scratch=$(mktemp -d "${TMPDIR:-${XDG_RUNTIME_DIR:-/var/tmp}}/reset-recovery.XXXXXXXX") || {
        it_fail "reset recovery reserves private scratch" "could not create a private baseline snapshot directory"
        umask "$saved_umask"
        return 1
    }
    if ! rx 'cat config.json' >"$scratch/original.json" || [ ! -s "$scratch/original.json" ] ||
        ! original_config=$(rx 'sha256sum config.json') || [ -z "$original_config" ] ||
        ! original_secrets=$(upgrade_secret_fingerprints) || [ -z "$original_secrets" ]; then
        it_fail "reset recovery saves the original baseline" "configuration or secret snapshot unreadable"
        rm -f -- "$scratch/original.json"
        rmdir "$scratch"
        umask "$saved_umask"
        return 1
    fi
    if ! rx 'cat config.reference.json' >"$scratch/reference.json" ||
        ! jq --slurpfile original "$scratch/original.json" '
            def candidate($saved):
                with_entries(select(.key != "_docs" and .key != "config_version") |
                    .key as $key |
                    select(($saved | type) == "object" and ($saved | has($key))) |
                    .value |= if type == "object" then candidate($saved[$key]) else $saved[$key] end);
            candidate($original[0])
        ' "$scratch/reference.json" >"$scratch/fixture.json" ||
        ! jq -e --slurpfile original "$scratch/original.json" '
            . as $fixture |
            all($original[0] | paths | select(any(.[]; type == "string" and test("wallet|payout|view_key|spend_public_key|donor_id")));
                . as $path | ($fixture | any(paths; . == $path)) and
                    (($fixture | getpath($path)) == ($original[0] | getpath($path))))
        ' "$scratch/fixture.json" >/dev/null; then
        it_fail "reset recovery projects a candidate-compatible fixture" "reference unreadable or a wallet/payout field would be lost"
        rc=1
    else
        mutated=1
        if rx 'umask 077; cat >config.json' --stdin <"$scratch/fixture.json" &&
            pithead apply -y 2>&1 | redact >"$OUT_DIR/reset-restore.fixture-apply.log" &&
            rx 'cat config.json' >"$scratch/applied.json" &&
            jq -en --slurpfile original "$scratch/original.json" --slurpfile reference "$scratch/reference.json" --slurpfile applied "$scratch/applied.json" '
                def stamp: if type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$") then . else null end;
                ($reference[0].config_version | stamp) as $candidate |
                select($candidate != null and $applied[0].config_version == $candidate) |
                {baseline_version: ($original[0].config_version | stamp), candidate_version: $candidate, fixture_version: $applied[0].config_version}
            ' >"$scratch/receipt.json" && mv -- "$scratch/receipt.json" "$OUT_DIR/reset-restore.fixture.json"; then
            run_reset_restore_fixture || rc=1
        else
            it_fail "reset recovery applies its synthetic fixture" "see reset-restore.fixture-apply.log"
            rc=1
        fi
    fi
    if [ "$mutated" -eq 1 ]; then
        pithead down 2>&1 | redact >"$OUT_DIR/reset-restore.cleanup.log" || verified=0
        if rx 'umask 077; cat >config.json' --stdin <"$scratch/original.json" &&
            pithead apply -y 2>&1 | redact >>"$OUT_DIR/reset-restore.cleanup.log" &&
            rx 'umask 077; cat >config.json' --stdin <"$scratch/original.json" &&
            pithead up 2>&1 | redact >>"$OUT_DIR/reset-restore.cleanup.log"; then
            wait_status_ok 240 || verified=0
        else
            verified=0
        fi
    fi
    if ! rx 'cat config.json' >"$scratch/restored.json" || ! cmp -s "$scratch/original.json" "$scratch/restored.json" ||
        ! after_config=$(rx 'sha256sum config.json') || [ "$after_config" != "$original_config" ] ||
        ! after_secrets=$(upgrade_secret_fingerprints) || [ "$after_secrets" != "$original_secrets" ]; then
        verified=0
    fi
    if [ "$verified" -eq 1 ]; then
        it_pass "reset recovery returns the original baseline bytes, secrets and healthy stack"
        rm -f -- "$scratch/original.json" "$scratch/reference.json" "$scratch/fixture.json" "$scratch/applied.json" "$scratch/receipt.json" "$scratch/restored.json"
        rmdir "$scratch" || rc=1
    else
        RESET_RESTORE_STACK_INTACT=0
        it_fail "reset recovery returns the original baseline bytes, secrets and healthy stack" "cleanup unverified; private recovery copy retained"
        rc=1
    fi
    umask "$saved_umask"
    return "$rc"
}

run_reset_restore_fixture() {
    RESET_RESTORE_STACK_INTACT=0
    local before_config before_secrets archive out rc after_config after_secrets
    local failures_before="$IT_FAIL"
    it_step "encrypted backup → config-reset → restore without rendered configuration…"
    post_op_begin
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
    rx "printf 'config-reset\\n' | $IT_PITHEAD config-reset" 2>&1 |
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
    local residue
    if residue=$(reset_restore_wait_empty 60); then
        it_pass "config-reset leaves no pithead-project containers in any state"
    else
        it_fail "config-reset leaves no pithead-project containers in any state" "project residue or engine read failure before configless down: ${residue:-unreadable}"
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
        redact >"$OUT_DIR/reset-restore.restore.log" || ! pithead up 2>&1 |
        redact >"$OUT_DIR/reset-restore.up.log"; then
        it_fail "encrypted restore after config-reset starts the stack" "restore or up failed; see reset-restore logs"
        return 1
    fi
    rr_web_ports_owned_by_dashboard "reset recovery" || return 1
    if wait_status_ok 600; then
        it_pass "stack healthy after encrypted restore following config-reset"
        POI_PROBES_ALLOWED=1 post_op_invariants "after reset recovery"
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

reset_restore_wait_empty() {
    local deadline=$(($(date +%s) + $1)) residue
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if residue=$(rx "docker ps --all --quiet --filter label=com.docker.compose.project=pithead" 2>/dev/null) && [ -z "$residue" ]; then
            return 0
        fi
        sleep 2
    done
    printf '%s\n' "${residue:-unreadable}"
    return 1
}
