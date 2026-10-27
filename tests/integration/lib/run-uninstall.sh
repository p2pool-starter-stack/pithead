# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

_uninstall_retain_diagnostic() {
    local tmp
    tmp=$(mktemp "$OUT_DIR/.uninstall-diagnostic.XXXXXX") || return 1
    if (
        set -o pipefail
        printf '%s\n' "$2" | redact >"$tmp"
    ) && mv -fT -- "$tmp" "$OUT_DIR/$1"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

_uninstall_data_dirs() {
    rx 'set -e; source ./pithead </dev/null; for key in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR TOR_DATA_DIR; do value=$(env_get_file .env "$key"); test -n "$value"; printf "%s\n" "$value"; done'
}

_uninstall_host_inventory() {
    rx 'set -eo pipefail
        docker container ls -aq --no-trunc | LC_ALL=C sort
        docker image ls -q --no-trunc | LC_ALL=C sort
        docker volume ls -q | LC_ALL=C sort
        units=$(systemctl list-unit-files --no-legend && systemctl list-units --all --no-legend)
        printf "%s\n" "$units" | awk "/pithead-(control|egress|lan)[-.]/ { \$1=\$1; print }" | LC_ALL=C sort
        sudo -n iptables-save | sed -E "/^#/d; s/^(:[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)\\[[0-9]+:[0-9]+\\]$/\\1[0:0]/"
        if command -v nft >/dev/null; then sudo -n nft list tables | LC_ALL=C sort; fi'
}

_uninstall_quiesce() {
    # The LAN recovery timer otherwise restarts stopped nodes.
    _lan_timer_pause &&
        rx 'case "$(systemctl is-active pithead-lan.timer)" in inactive|failed) ;; *) exit 1 ;; esac' &&
        rx 'docker compose stop' >/dev/null 2>&1
}

_uninstall_setup() {
    rx "install -m 600 .env.itest-round-trip .env && sed -i '/^DEPLOYMENT_COMPLETED=/d' .env" &&
        rx "PITHEAD_PULL=missing $IT_PITHEAD setup --skip-deps --skip-optimize" &&
        rx 'rm -f .env.itest-round-trip && test ! -e .env.itest-round-trip'
}

_uninstall_prepare_restore() {
    local state out rc=0
    state=$(rx 'if test -f .env.itest-round-trip; then echo removed; elif test -e .env; then echo configured; else echo empty; fi') || return 1
    case "$state" in
    configured) return 0 ;;
    removed)
        out="$(_uninstall_setup 2>&1)" || rc=$?
        _uninstall_retain_diagnostic uninstall-reprovision.log "$out" || it_warn "Could not retain the uninstall re-provisioning diagnostic."
        return "$rc"
        ;;
    *) return 1 ;;
    esac
}

_uninstall_capture_baseline() {
    local dir
    local -a kept=()
    data_dirs="$(_uninstall_data_dirs)" && [ "$(printf '%s\n' "$data_dirs" | wc -l)" -eq 5 ] || return 1
    while IFS= read -r dir; do kept+=("$dir"); done <<<"$data_dirs"
    kept_snapshot="$(kept_data_snapshot_snippet "${kept[@]}" config.json backups)"
    _uninstall_quiesce &&
        kept_before="$(rx "$kept_snapshot")" && [ -n "$kept_before" ] &&
        compose_ids_before="$(rx 'docker compose ps -aq')" && [ -n "$compose_ids_before" ]
}

_uninstall_phase_recover() {
    local cleanup_ok=1 restore_ok=1
    safety_restore_exact || restore_ok=0
    rx 'rm -f .env.itest-round-trip && test ! -e .env.itest-round-trip' || cleanup_ok=0
    if [ "$cleanup_ok$restore_ok" = 11 ]; then
        it_pass "uninstall phase restored the exact healthy baseline without outer rollback"
        return 0
    fi
    # shellcheck disable=SC2034
    SAFETY_RESTORE_FAILED=1
    it_fail "uninstall phase restored the exact healthy baseline without outer rollback" "temporary secret copy cleanup or exact recovery failed: $SAFETY_RESTORE_FAIL_REASON"
    return 1
}

_uninstall_after_remove() {
    local containers units firewall id left=0 missing=0 dir kept_after
    if kept_after="$(rx "$kept_snapshot")"; then
        if [ "$kept_after" = "$kept_before" ]; then
            it_pass "uninstall preserves every configured data dir byte-identically"
        else
            it_fail "uninstall preserves every configured data dir byte-identically" "a kept file or directory changed"
        fi
    else
        it_fail "uninstall preserves every configured data dir byte-identically" "kept-path snapshot failed"
    fi
    if containers="$(rx 'docker container ls -aq --no-trunc')"; then
        while IFS= read -r id; do
            [ -z "$id" ] || ! grep -Fxq "$id" <<<"$containers" || left=$((left + 1))
        done <<<"$compose_ids_before"
        assert_eq "compose project removed" "$left" "0"
    else
        it_fail "compose project removed" "Docker container inventory failed"
    fi
    if units="$(rx 'systemctl list-unit-files --no-legend && systemctl list-units --all --no-legend')"; then
        assert_eq "every pithead systemd unit removed (control runner, egress, LAN guard)" \
            "$(grep -Ec 'pithead-(control|egress|lan)[-.]' <<<"$units" || true)" "0"
        if grep -Eq 'pithead-(control|egress|lan)[-.]' <<<"$units"; then
            if _uninstall_retain_diagnostic uninstall-systemd-units.log "$(grep -E 'pithead-(control|egress|lan)[-.]' <<<"$units")"; then
                it_warn "Remaining systemd unit records (first 80 lines):"
                sed -n '1,80p' "$OUT_DIR/uninstall-systemd-units.log"
            else
                it_warn "Could not retain the remaining systemd unit diagnostic."
            fi
        fi
    else
        it_fail "every pithead systemd unit removed (control runner, egress, LAN guard)" "systemd inventory failed"
    fi
    if firewall="$(rx 'set -e; sudo -n iptables-save; if command -v nft >/dev/null; then sudo -n nft list tables; fi')"; then
        assert_eq "tor egress firewall rules removed from the kernel" \
            "$(grep -Ec 'pithead-tor-egress|table inet pithead_egress' <<<"$firewall" || true)" "0"
    else
        it_fail "tor egress firewall rules removed from the kernel" "kernel rule inventory failed"
    fi
    assert_contains "the kept message names config.json" "$1" "config.json"
    while IFS= read -r dir; do
        [[ "$1" == *"$dir"* ]] || missing=$((missing + 1))
    done <<<"$data_dirs"
    assert_eq "the kept message names every configured data dir" "$missing" "0"
    [ "$IT_FAIL" -eq "$phase_fails_before" ] || return 1
    [ "${UNINSTALL_INJECT_RECOVERY:-0}" != 1 ] || return 99
}

run_uninstall_phase() {
    local phase_fails_before="$IT_FAIL" data_dirs compose_ids_before kept_snapshot kept_before before after snapshot abort_out abort_rc rc before_host after_host after_kept drift=""
    # shellcheck disable=SC2034
    IT_CURRENT_SCENARIO="uninstall"
    it_log "── uninstall phase ─────────────────────────"
    snapshot="$(kept_data_snapshot_snippet .env Caddyfile)"
    if ! _uninstall_capture_baseline ||
        ! before="$(rx "$snapshot")" || [ -z "$before" ] ||
        ! before_host="$(_uninstall_host_inventory)"; then
        it_fail "abort baseline captured before uninstall" "quiescing, file snapshot, or host inventory failed"
        _uninstall_phase_recover || return 1
        return 1
    fi
    abort_out="$(rx "printf 'nope\n' | $IT_PITHEAD uninstall" 2>&1)"
    abort_rc=$?
    assert_rc "aborted uninstall exits 1" "$abort_rc" "1"
    assert_contains "aborted uninstall reports nothing changed" "$abort_out" "Aborted"
    assert_eq ".env still present after the abort" "$(rx 'test -f .env && echo yes || echo no')" "yes"
    if after="$(rx "$snapshot")" && after_host="$(_uninstall_host_inventory)" &&
        after_kept="$(rx "$kept_snapshot")"; then
        if [ "$after" = "$before" ] && [ "$after_host" = "$before_host" ] && [ "$after_kept" = "$kept_before" ]; then
            it_pass "aborted uninstall preserves every file and host resource"
        else
            [ "$after" = "$before" ] || drift="$drift checkout files;"
            [ "$after_host" = "$before_host" ] || drift="$drift host resources;"
            [ "$after_kept" = "$kept_before" ] || drift="$drift kept paths;"
            it_fail "aborted uninstall preserves every file and host resource" "changed:$drift"
            if [ "$after_kept" != "$kept_before" ]; then
                it_warn "Kept-path hash/metadata differences (first 80 lines):"
                diff -u <(printf '%s\n' "$kept_before") <(printf '%s\n' "$after_kept") | sed -n '1,80p' || true
            fi
        fi
    else
        it_fail "aborted uninstall preserves every file and host resource" "post-abort snapshot failed"
    fi
    if [ "$IT_FAIL" -ne "$phase_fails_before" ]; then
        _uninstall_phase_recover || return 1
        return 1
    fi

    # Interrupt after real removal to prove recovery without the runner's outer restore.
    local UNINSTALL_INJECT_RECOVERY=1
    run_uninstall_round_trip
    rc=$?
    if [ "$rc" -ne 99 ] || [ "$IT_FAIL" -ne "$phase_fails_before" ]; then
        it_fail "uninstall recovery fault reached the uninstalled checkout" "expected injected return 99, got $rc"
        _uninstall_phase_recover || return 1
        return 1
    fi
    it_pass "uninstall recovery fault reached the uninstalled checkout"
    _uninstall_phase_recover || return 1
    _SAFETY_RESTORE_ARMED=1
    UNINSTALL_INJECT_RECOVERY=0
    if ! _uninstall_capture_baseline; then
        it_fail "recovered uninstall baseline is readable" "data or container inventory failed"
        _uninstall_phase_recover || return 1
        return 1
    fi
    if ! run_uninstall_round_trip || [ "$IT_FAIL" -ne "$phase_fails_before" ]; then
        _uninstall_phase_recover || return 1
        return 1
    fi
    return 0
}
