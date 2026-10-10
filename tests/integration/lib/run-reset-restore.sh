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
    running_probe="set -e; stage=census;
        test -n \"\$(docker ps -q --filter label=com.docker.compose.project=pithead --filter status=running)\";
        stage=scratch; scratch=\$(mktemp -d \"\${TMPDIR:-/tmp}/reset-restore.XXXXXX\");
        trap 'rc=\$?; for f in config.json .env Caddyfile; do [ ! -e \"\$scratch/\$f\" ] || mv -- \"\$scratch/\$f\" \"\$f\"; done; rmdir -- \"\$scratch\"; [ \"\$rc\" -eq 0 ] || printf \"reset-restore probe: failed at %s (exit %s)\\n\" \"\$stage\" \"\$rc\" >&2' EXIT
        stage=hide; for f in config.json .env Caddyfile; do mv -- \"\$f\" \"\$scratch/\$f\"; done;
        stage=restore; set +e; output=\$($IT_PITHEAD restore -y $(quote_arg "$archive") </dev/null 2>&1); result=\$?; set -e;
        stage=refusal; {
            printf \"restore exit=%s running=%s first-line=%s\\n\" \"\$result\" \"\$(docker ps -q --filter label=com.docker.compose.project=pithead --filter status=running | wc -l)\" \"\$(printf %s \"\$output\" | head -n 1 | cut -c1-200)\";
            printf \"present after restore:\"; for f in config.json .env Caddyfile; do [ ! -e \"\$f\" ] || printf \" %s\" \"\$f\"; done; printf \"\\n\";
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
        probe_err=$(printf '%s' "$probe_err" | grep -v 'Permanently added' | redact | tail -n 8)
        # Restore refused (non-zero exit) and left every file absent: the stack is as it was, so
        # the phases after lifecycle can still run. Any other failure keeps the phase stopped.
        if grep -q 'restore exit=[1-9] running=[1-9]' <<<"$probe_err" && grep -qx 'present after restore:' <<<"$probe_err"; then
            # shellcheck disable=SC2034 # read by run_lifecycle
            RESET_RESTORE_STACK_INTACT=1
        fi
        # A Podman engine rejects status=restarting, so the configless census cannot finish (#3346).
        case "$probe_err" in *'configless census stderr'*) probe_err="restore could not take its configless census; see #3346. $probe_err" ;; esac
        it_fail "restore refuses real running containers with all configuration missing" "running census, refusal, or unchanged-file assertion failed: ${probe_err:-no output}"
        return 1
    fi

    if ! rx "printf 'config-reset\\n' | $IT_PITHEAD config-reset" 2>&1 |
        redact >"$OUT_DIR/reset-restore.reset.log" ||
        ! rx 'test ! -e config.json && test ! -e .env && test ! -e Caddyfile'; then
        it_fail "config-reset removes configuration before encrypted recovery" "reset failed or a rendered file remains; see reset-restore.reset.log"
        return 1
    fi
    it_pass "config-reset removes configuration before encrypted recovery"
    if pithead down 2>&1 | redact >"$OUT_DIR/reset-restore.down.log"; then
        it_pass "pithead down succeeds after reset without Compose interpolation"
    else
        it_fail "pithead down succeeds after reset without Compose interpolation" "down failed; see reset-restore.down.log"
        return 1
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
