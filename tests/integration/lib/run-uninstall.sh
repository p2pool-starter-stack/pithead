# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# --uninstall phase (#2343): `uninstall` is the DIY channel's clean exit and, before this, the
# only harness that ever ran it was tier-1's sandbox with docker/sudo stubbed out. This proves the
# abort path changes nothing, the keep-list (config.json + the *_DATA_DIR paths named in the
# "kept" message) survives on the REAL disk — same size and file count before and after, a wipe or
# truncation moves either — the kernel firewall rules and the systemd control units it installed
# are REALLY gone, then that `setup` re-provisions the checkout from what was kept — no resync, the
# round trip the verb's own closing message promises. DESTRUCTIVE, ordered last: it tears the
# checkout down and puts it back itself, so it does not depend on the box's normal down/apply
# restore.
run_uninstall_phase() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="uninstall"
    echo ""
    it_log "── uninstall phase (#2343) ─────────────────────────"

    it_step "abort path (wrong confirm word)…"
    local abort_out abort_rc
    abort_out="$(rx "printf 'nope\n' | $IT_PITHEAD uninstall" 2>&1)"
    abort_rc=$?
    assert_rc "aborted uninstall exits 1" "$abort_rc" "1"
    assert_contains "aborted uninstall reports nothing changed" "$abort_out" "Aborted"
    assert_eq ".env still present after the abort" "$(rx 'test -f .env && echo yes || echo no')" "yes"

    # The keep-list, read the same way the verb reads it: from .env BEFORE it is removed. Strips
    # the surrounding quotes dotenv_render_value adds for a path with spaces/$/"/\ (#19); a
    # data dir plain enough to need none round-trips through the strip unchanged.
    local dirs dir fp_before="" fp_after="" config_before
    dirs="$(rx "grep -E '^(MONERO|TARI|P2POOL|DASHBOARD|TOR)_DATA_DIR=' .env 2>/dev/null | cut -d= -f2-" | sort -u)"
    dirs="$(printf '%s\n' "$dirs" | sed -e 's/^"//' -e 's/"$//')"
    for dir in $dirs; do
        [ -n "$dir" ] || continue
        fp_before="${fp_before}${dir}=$(rx "du -sb $(quote_arg "$dir") 2>/dev/null | cut -f1")/$(rx "find $(quote_arg "$dir") -type f 2>/dev/null | wc -l | tr -d ' '");"
    done
    config_before="$(rx 'cat config.json' 2>/dev/null)"

    it_step "pithead uninstall -y…"
    if ! pithead uninstall -y >"$OUT_DIR/uninstall.log" 2>&1; then
        it_fail "uninstall succeeded" "see $OUT_DIR/uninstall.log"
        return
    fi

    assert_eq "compose project removed" \
        "$(rx 'docker compose ps -q 2>/dev/null | wc -l | tr -d " "')" "0"
    assert_eq "control-runner systemd units removed" \
        "$(rx 'systemctl list-unit-files "pithead-control*" 2>/dev/null | grep -c pithead-control')" "0"
    assert_eq "tor egress firewall rules removed from the kernel" \
        "$(rx 'sudo iptables-save 2>/dev/null | grep -c pithead-tor-egress')" "0"
    assert_eq ".env removed" "$(rx 'test -f .env && echo yes || echo no')" "no"
    assert_eq "config.json kept, byte-identical" "$(rx 'cat config.json' 2>/dev/null)" "$config_before"

    local uninstall_log
    uninstall_log="$(cat "$OUT_DIR/uninstall.log" 2>/dev/null)"
    assert_contains "the kept message names config.json" "$uninstall_log" "config.json"
    assert_contains "the kept message names backups/" "$uninstall_log" "backups/"
    for dir in $dirs; do
        [ -n "$dir" ] || continue
        assert_contains "the kept message names $dir" "$uninstall_log" "$dir"
        fp_after="${fp_after}${dir}=$(rx "du -sb $(quote_arg "$dir") 2>/dev/null | cut -f1")/$(rx "find $(quote_arg "$dir") -type f 2>/dev/null | wc -l | tr -d ' '");"
    done
    assert_eq "kept data dirs unchanged on disk (size + file-count fingerprint)" "$fp_after" "$fp_before"

    it_step "re-provisioning from the kept config.json (pithead setup)…"
    if ! pithead setup >"$OUT_DIR/uninstall-setup.log" 2>&1; then
        it_fail "setup re-provisioned the uninstalled checkout" "see $OUT_DIR/uninstall-setup.log"
        return
    fi
    wait_status_ok 240 || it_fail "stack healthy after re-provisioning" "pithead status did not become OK"
    assert_eq "re-provisioned config matches the kept one" "$(rx 'cat config.json' 2>/dev/null)" "$config_before"
    assert_running_state "uninstall" "$BASELINE_CONFIG"
}
