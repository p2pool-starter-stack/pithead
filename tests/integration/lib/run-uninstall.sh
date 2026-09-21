# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# --uninstall phase (#2343): `uninstall` is the DIY channel's clean exit and, before this, the
# only harness that ever ran it was tier-1's sandbox with docker/sudo stubbed out. This proves the
# abort path changes nothing, the keep-list (config.json + the *_DATA_DIR paths named in the
# "kept" message) survives on the REAL disk, the kernel firewall rules and the systemd control
# units it installed are REALLY gone, then that `setup` re-provisions the checkout from what was
# kept — no resync, the round trip the verb's own closing message promises. DESTRUCTIVE, ordered
# last: it tears the checkout down and puts it back itself, so it does not depend on the box's
# normal down/apply restore — and it owns its OWN recovery on a failure (see
# _uninstall_phase_recover) rather than leaning on the harness's generic safety rollback, whose
# 240s wait is sized for a hot apply, not a full re-provision (#2343 job 635).
#
# Job 635's first real-box run measured both snapshots wrong: `fp_before` was taken while the
# stack was still RUNNING, so a live LMDB/SQLite writer made monero/tari/dashboard look different
# after uninstall's own shutdown — not a wipe, a shutdown checkpoint the "before" snapshot never
# saw. Both snapshots are now taken with the stack already stopped (this phase's own `down` before
# `fp_before`; uninstall's internal `down` on an already-down stack is a no-op), and the aggregate
# size+count check is replaced with per-file content hashes, so a real deletion or rewrite
# shows up as a named path in the diff instead of a number that a shutdown checkpoint can also move.
_uninstall_dir_listing() { # <dir> -> "<sha256> <path>" lines, sorted; a stable snapshot
    rx "test -d $(quote_arg "$1") && test ! -L $(quote_arg "$1") && find $(quote_arg "$1") -type f -exec sha256sum {} + | sort"
}

_uninstall_snapshot_dirs() { # <newline-separated dirs> -> one labeled listing block per dir
    local dir
    for dir in $1; do
        [ -n "$dir" ] || continue
        printf '=== %s ===\n%s\n' "$dir" "$(_uninstall_dir_listing "$dir")"
    done
}

# Self-heal (#2343 job 635): a failure partway through the destructive step below must not strand
# the box for the outer safety rollback to find — this phase requires --safety-backup, so the
# pre-run archive is right here. Puts the box back with the SAME restore this phase already
# validates elsewhere (backup -> restore -> up), not a repeat of whichever step just failed.
_uninstall_phase_recover() { # <IT_FAIL count before the destructive step>
    [ "$IT_FAIL" -gt "$1" ] || return 0
    it_warn "uninstall phase failed — restoring the pre-run safety archive and bringing the stack back…"
    pithead down >/dev/null 2>&1
    pithead restore -y "$SAFETY_ARCHIVE" >/dev/null 2>&1
    pithead up >/dev/null 2>&1
    wait_status_ok 240 || it_warn "uninstall phase recovery did not report healthy — the outer safety rollback will retry"
}

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
    local dirs dir snapshot_paths fp_before fp_after config_before config_before_fp setup_secret_fp first_party_images pulled_images img
    dirs="$(rx "grep -E '^(MONERO|TARI|P2POOL|DASHBOARD|TOR)_DATA_DIR=' .env 2>/dev/null | cut -d= -f2-" | sort -u)"
    dirs="$(printf '%s\n' "$dirs" | sed -e 's/^"//' -e 's/"$//')"
    # Quiesce BEFORE the "before" snapshot (see the file header): both snapshots below are of a
    # stopped stack, so a clean-shutdown checkpoint (dashboard's sqlite -wal/-shm, tor's lock
    # file) already happened before either is taken, and can't be mistaken for uninstall wiping it.
    if ! pithead down >/dev/null 2>&1; then
        it_fail "stack quiesced before uninstall snapshot" "pithead down failed"
        return
    fi
    snapshot_paths="${dirs}"$'\nbackups'
    if ! fp_before="$(_uninstall_snapshot_dirs "$snapshot_paths")"; then
        it_fail "kept data and backups are readable before uninstall" "a configured path is missing, symlinked, or unreadable"
        return
    fi
    config_before="$(rx 'cat config.json' 2>/dev/null)"
    config_before_fp="$(printf '%s' "$config_before" | sha256sum | cut -d' ' -f1)"
    if ! img="$(rx 'docker compose config --images')"; then
        it_fail "compose image inventory captured" "docker compose config --images failed"
        return
    fi
    while IFS= read -r dir; do
        case "$dir" in
        "${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-"*) first_party_images+="${dir}"$'\n' ;;
        *) [ -n "$dir" ] && pulled_images+="${dir}"$'\n' ;;
        esac
    done <<<"$img"

    local fails_before="$IT_FAIL"
    it_step "pithead uninstall -y…"
    if ! pithead uninstall -y >"$OUT_DIR/uninstall.log" 2>&1; then
        it_fail "uninstall succeeded" "see $OUT_DIR/uninstall.log"
        _uninstall_phase_recover "$fails_before"
        return
    fi

    local compose_ids control_units firewall_rules
    if ! compose_ids="$(rx 'docker compose ps -q')"; then
        it_fail "compose project removed" "docker compose ps failed"
    else
        assert_eq "compose project removed" "$(printf '%s\n' "$compose_ids" | sed '/^$/d' | wc -l | tr -d ' ')" "0"
    fi
    if ! control_units="$(rx 'systemctl list-unit-files "pithead-control*" --no-legend && systemctl list-units --all "pithead-control*" --no-legend')"; then
        it_fail "control-runner systemd units removed" "systemctl inspection failed"
    else
        assert_eq "control-runner systemd units removed" "$(printf '%s\n' "$control_units" | grep -c pithead-control || true)" "0"
    fi
    if ! firewall_rules="$(rx 'if command -v nft >/dev/null; then sudo nft list tables; fi; sudo iptables-save')"; then
        it_fail "tor egress firewall rules removed from the kernel" "firewall inspection failed"
    else
        assert_eq "tor egress firewall rules removed from the kernel" "$(printf '%s\n' "$firewall_rules" | grep -Ec 'pithead-tor-egress|table inet pithead_egress' || true)" "0"
    fi
    while IFS= read -r img; do
        [ -n "$img" ] || continue
        if rx "docker image inspect $(quote_arg "$img") >/dev/null 2>&1"; then
            it_fail "pithead-built image removed" "$img remains after uninstall"
        else
            it_pass "pithead-built image removed"
        fi
    done <<<"$first_party_images"
    while IFS= read -r img; do
        [ -n "$img" ] || continue
        if rx "docker image inspect $(quote_arg "$img") >/dev/null 2>&1"; then
            it_pass "pulled third-party image kept"
        else
            it_fail "pulled third-party image kept" "$img is absent after uninstall"
        fi
    done <<<"$pulled_images"
    assert_eq ".env removed" "$(rx 'test -f .env && echo yes || echo no')" "no"
    assert_eq "config.json kept, byte-identical" "$(rx "sha256sum config.json 2>/dev/null | cut -d' ' -f1")" "$config_before_fp"

    local uninstall_log
    uninstall_log="$(cat "$OUT_DIR/uninstall.log" 2>/dev/null)"
    assert_contains "the kept message names config.json" "$uninstall_log" "config.json"
    assert_contains "the kept message names backups/" "$uninstall_log" "backups/"
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        assert_contains "the kept message names $dir" "$uninstall_log" "$dir"
    done <<<"$dirs"
    if ! fp_after="$(_uninstall_snapshot_dirs "$snapshot_paths")"; then
        it_fail "kept data and backups are readable after uninstall" "a configured path is missing, symlinked, or unreadable"
    elif [ "$fp_after" = "$fp_before" ]; then
        it_pass "kept data dirs unchanged on disk (per-file content hashes, stack quiesced both sides)"
    else
        it_fail "kept data dirs unchanged on disk (per-file content hashes, stack quiesced both sides)" \
            "$(diff <(printf '%s\n' "$fp_before") <(printf '%s\n' "$fp_after") | head -40)"
    fi

    it_step "re-provisioning from the kept config.json (pithead setup)…"
    if ! pithead setup >"$OUT_DIR/uninstall-setup.log" 2>&1; then
        it_fail "setup re-provisioned the uninstalled checkout" "see $OUT_DIR/uninstall-setup.log"
        _uninstall_phase_recover "$fails_before"
        return
    fi
    wait_status_ok 240 || it_fail "stack healthy after re-provisioning" "pithead status did not become OK"
    assert_eq "re-provisioned config matches the kept one" "$(rx "sha256sum config.json 2>/dev/null | cut -d' ' -f1")" "$config_before_fp"
    setup_secret_fp="$(secret_fingerprint)"
    if rx "grep -qE '^PROXY_AUTH_TOKEN=.+$' .env && grep -qE '^[A-Z]+_ONION_ADDRESS=.+$' .env"; then
        it_pass "re-provisioned proxy and onion state populated"
    else
        it_fail "re-provisioned proxy and onion state populated" "required proxy or onion state is missing"
    fi
    assert_running_state "uninstall" "$config_before" "$setup_secret_fp"
    _uninstall_phase_recover "$fails_before"
}
