# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# The ordinary CLI recovery door, using real Compose containers and a real encrypted backup.
# RESET_RESTORE_STACK_INTACT=1 on return marks a failure that changed nothing, so run_lifecycle can
# go on and the phases after it still run (#3342).
run_reset_restore() {
    RESET_RESTORE_STACK_INTACT=0
    local before_config before_secrets archive out rc after_config after_secrets
    local failures_before="$IT_FAIL"
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
    rx "printf 'config-reset\\n' | $IT_PITHEAD config-reset" 2>&1 |
        redact >"$OUT_DIR/reset-restore.reset.log"
    # The appliance reboots into first-boot setup right after the reset; every later step waits for it.
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
    reset_restore_refusals "$archive" || return 1
    if ! rx "PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' $IT_PITHEAD restore -y $(quote_arg "$archive")" 2>&1 |
        redact >"$OUT_DIR/reset-restore.restore.log"; then
        it_fail "encrypted restore after config-reset restores the archive" "restore failed; see reset-restore.restore.log"
        return 1
    fi
    if reset_restore_state_probe verify "$archive" >"$OUT_DIR/reset-restore.verify.log" 2>&1; then
        it_pass "reset recovery preserves archived data and every database table before up"
    else
        it_fail "reset recovery preserves archived data and every database table before up" "archive bytes, database integrity, foreign keys or exact table counts differ; see reset-restore.verify.log"
        return 1
    fi
    if ! pithead up 2>&1 | redact >"$OUT_DIR/reset-restore.up.log"; then
        it_fail "encrypted restore after config-reset starts the stack" "up failed; see reset-restore.up.log"
        return 1
    fi
    rr_web_ports_owned_by_dashboard "reset recovery" || return 1
    if wait_status_ok 600; then
        it_pass "stack healthy after encrypted restore following config-reset"
    else
        it_fail "stack healthy after encrypted restore following config-reset" "status did not recover"
        return 1
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

reset_restore_state_command() {
    local payload args="" argument privilege="sudo -n"
    [ "$1" != future ] || privilege=""
    payload=$(base64 <"${BASH_SOURCE[0]%/*}/restore-state-probe.py" | tr -d '\n') || return 1
    for argument in "$@"; do args+=" $(quote_arg "$argument")"; done
    printf 'printf %%s %s | base64 -d | %s env TMPDIR="${TMPDIR:-$PWD}" python3 -%s' "$(quote_arg "$payload")" "$privilege" "$args"
}

reset_restore_state_probe() {
    local command
    command=$(reset_restore_state_command "$@") || return 1
    rx "$command"
}

reset_restore_nochange_snapshot() {
    local files containers
    files=$(reset_restore_state_probe snapshot "$1") && [ -n "$files" ] || return 1
    containers=$(rx 'docker ps --all --quiet --filter label=com.docker.compose.project=pithead') || return 1
    [ -z "$containers" ] || return 1
    printf '%s\n' "$files"
}

reset_restore_refusals() {
    local archive="$1" before after kind out rc expected command future
    before=$(reset_restore_nochange_snapshot "$archive") || {
        it_fail "restore refusals capture unchanged configless state" "Tor, database or project census unreadable"
        return 1
    }
    for kind in wrong-passphrase truncated newer-config; do
        case "$kind" in
        wrong-passphrase)
            command="PITHEAD_BACKUP_PASSPHRASE='wrong reset recovery fixture' $IT_PITHEAD restore -y $(quote_arg "$archive")"
            expected="Wrong passphrase or corrupt archive"
            ;;
        truncated)
            command="scratch=\$(mktemp -d \"\${TMPDIR:-\$PWD}/restore-refusal.XXXXXX\") || exit 1; trap 'rm -rf -- \"\$scratch\"' EXIT;
                head -c 1024 $(quote_arg "$archive") >\"\$scratch/truncated.tar.gz.enc\" &&
                PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' $IT_PITHEAD restore -y \"\$scratch/truncated.tar.gz.enc\""
            expected="Archive fails integrity verification"
            ;;
        newer-config)
            future=$(reset_restore_state_command future "$archive") || return 1
            command="scratch=\$(mktemp -d \"\${TMPDIR:-\$PWD}/restore-refusal.XXXXXX\") || exit 1; trap 'rm -rf -- \"\$scratch\"' EXIT;
                $future \"\$scratch/future.tar.gz.enc\" &&
                PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' $IT_PITHEAD restore -y \"\$scratch/future.tar.gz.enc\""
            expected="This backup's configuration was written by pithead"
            ;;
        esac
        out=$(rx "$command" 2>&1)
        rc=$?
        printf '%s\n' "$out" | redact >"$OUT_DIR/reset-restore.$kind.log"
        after=$(reset_restore_nochange_snapshot "$archive") || after=""
        if [ "$rc" -eq 1 ] && [[ "$out" == *"$expected"* ]] && [ "$after" = "$before" ]; then
            it_pass "restore refuses $kind without changing files or containers"
        else
            it_fail "restore refuses $kind without changing files or containers" "exit, cause or unchanged-state assertion failed; see reset-restore.$kind.log"
            return 1
        fi
    done
}
