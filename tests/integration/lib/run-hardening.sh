# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
_set_env_token() { # _set_env_token <value>
    rx "awk -v t=$(quote_arg "$1") '/^PROXY_AUTH_TOKEN=/{print \"PROXY_AUTH_TOKEN=\" t; next} {print}' .env > .env.itest && mv .env.itest .env"
}

# Drop a file into the control spool on the box (mirrors push_config's stdin-over-ssh transfer so
# no JSON quoting has to survive the remote shell string). <abs-path> is on the box.
_spool_write() { # _spool_write <abs-path-on-box> <content>
    if [ "$IT_MODE" = "local" ]; then
        printf '%s\n' "$2" >"$1"
    else
        printf '%s\n' "$2" | ssh "${IT_SSH_OPTS[@]}" "$IT_SSH_DEST" "cat > $(quote_arg "$1")"
    fi
}

# A fresh lowercase uuid4 for each control round-trip. The real dashboard mints one per
# preview→commit cycle (control_service.submit: str(uuid4())) and NEVER reuses it; a hardcoded id
# reused across runs collides with the results/ that pithead never sweeps, so the preview's
# "wait for any status" reads a STALE "applied" from a prior run and the commit races the real
# staging. A per-run id has no prior result on disk, so the wait proves THIS request settled.
_uuid4() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        uuidgen | tr 'A-F' 'a-f'
    fi
}

# Wait up to <timeout>s for the systemd path unit to write results/<id>.json with a status OTHER
# than <exclude> (so a leftover preview result doesn't satisfy a wait for the commit result).
# Returns 0 and echoes the status when it settles; 1 on timeout. Proof the unit actually fired.
_wait_control_status() { # <control-dir> <id> <exclude-status> <timeout>
    local cdir="$1" id="$2" exclude="$3" timeout="${4:-90}" waited=0 st
    while [ "$waited" -lt "$timeout" ]; do
        st="$(rx "jq -r '.status // empty' $(quote_arg "$cdir/results/$id.json") 2>/dev/null")"
        if [ -n "$st" ] && [ "$st" != "$exclude" ]; then
            echo "$st"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# Reach the dashboard onion from an INDEPENDENT external Tor client — its own tor + curl, its own
# circuits, sharing nothing with the stack (tests/integration/tor-client/). It reaches the onion
# over the REAL Tor network exactly as a remote user would, so a pass proves the whole inbound path
# (hidden service published + reachable, client-auth key accepted, Caddy answering) from OUTSIDE the
# trust boundary — using none of the stack's own SOCKS/plumbing. Returns 0 if Caddy answered (200 or
# 401 — we deliberately don't hold the login, so its auth challenge counts as reachable). The client
# key is piped pithead->container stdin entirely on the box: it never crosses to the harness, an ssh
# argument, or `docker inspect`. Everything runs on the bench (it has docker + the Tor network).
_onion_reachable_external() {
    local onion
    onion="$(env_on_box DASHBOARD_ONION_ADDRESS)"
    [ -n "$onion" ] && [ "$onion" != "placeholder" ] || return 2
    rx "docker build -q -t pithead-tor-client-test tests/integration/tor-client/ >/dev/null 2>&1" || return 3
    # onion is [a-z2-7]{56}.onion (safe to embed); the client key stays on the box.
    local snippet
    snippet="line=\$(./pithead onion-client-key 2>/dev/null | grep -E 'descriptor:x25519:' | head -1);"
    snippet="$snippet if [ -n \"\$line\" ]; then printf '%s\n' \"\$line\" | docker run -i --rm -e ONION_ADDR=$onion -e AUTH_STDIN=1 pithead-tor-client-test;"
    snippet="$snippet else docker run --rm -e ONION_ADDR=$onion pithead-tor-client-test; fi"
    rx "$snippet" | grep -q "PROBE-OK"
}

# Reap the root pithead-control systemd units THIS checkout installed, idempotently (#477).
# The hardening phase installs pithead-control.{path,service} to exercise the #33 spool; the restore
# apply is supposed to remove them, but that removal runs EARLY in apply (provision_control_runner) —
# before container recreation + the tor restart — so a restore apply that dies partway (render/preflight
# failure, or wait_status_ok timing out mid-apply) leaves the ROOT path unit watching the control spool
# past the phase and beyond. A later apply is convergent and would clean it, but only if it runs. This
# teardown mirrors provision_control_runner's removal branch and runs regardless of the restore
# apply's exit code. Units owned by ANOTHER checkout are left in place and count as success: the
# unit names are box-global, and on a shared bench the live stack's runner uses them too — reaping
# it strands that dashboard's control requests (config editor stuck at "Previewing…"). rx runs in
# $IT_REMOTE_DIR, so the snippet's working dir is this run's checkout on the box. Ownership
# compares PHYSICAL paths, mirroring the provision_control_runner branch: one checkout has two
# spellings (the `current` symlink vs the versioned dir production units carry). No-ops where
# there's no systemd (macOS/dev). Returns non-zero ONLY if a unit WE own survives (e.g. sudo
# unavailable) so the caller can warn loudly instead of silently passing.
_remove_control_units() {
    rx '
        command -v systemctl >/dev/null 2>&1 || exit 0
        ud=/etc/systemd/system
        if [ -e "$ud/pithead-control.service" ]; then
            owner_dir=$(sed -n "s|^ExecStart=\(/.*\)/pithead control-run-pending\$|\1|p" \
                "$ud/pithead-control.service" | head -n 1)
            dir=$owner_dir tail=""
            while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
                tail="/$(basename "$dir")$tail"
                dir=$(dirname "$dir")
            done
            if [ -z "$owner_dir" ] ||
                [ "$(cd "$dir" 2>/dev/null && pwd -P)$tail" != "$(pwd -P)" ]; then
                exit 0
            fi
        fi
        if [ -e "$ud/pithead-control.path" ] || [ -e "$ud/pithead-control.service" ]; then
            sudo systemctl disable --now pithead-control.path >/dev/null 2>&1 || true
            sudo rm -f "$ud/pithead-control.path" "$ud/pithead-control.service"
            sudo systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        [ ! -e "$ud/pithead-control.path" ] && [ ! -e "$ud/pithead-control.service" ]
    '
}

# Tier-4 hardening phase (#377/#33/#424): the v1.4 host-mutation + hardening surfaces that ONLY a
# real box proves — a read-only rootfs actually rejecting a write, the systemd path unit actually
# firing on a spooled request, and a tor restart restoring real clearnet egress. Local mode only
# (needs the real containers, data dirs, and systemd). Everything it changes is reverted by the
# end-of-run config restore; it also re-applies the baseline itself so the root path unit never lingers.
run_hardening() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="hardening"
    echo ""
    it_log "── v1.4 hardening phase (#377/#33/#424) ────────────"

    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_skip_phase "hardening" "remote mode: no local containers/systemd to exercise" "by-design"
        return 0
    fi

    # 1. Read-only rootfs is LIVE at runtime (#377), not just declared in compose. We must assert
    #    the failure is specifically EROFS ("Read-only file system"), NOT just any error: the
    #    containers run non-root (#255), so `touch /` on a WRITABLE rootfs already fails with EACCES
    #    ("Permission denied") — treating any failure as a pass would green-light a service that
    #    silently lost read_only. Only a read-only mount returns EROFS (verified: a writable
    #    non-root container gives Permission denied; a read-only one gives Read-only file system).
    #    /tmp is a writable tmpfs by design — we probe /, the image layer, not the scratch mount.
    local svc probe_out
    for svc in tor monerod p2pool tari xmrig-proxy dashboard; do
        probe_out="$(rx "docker exec $svc sh -c 'touch /.rootfs-write-probe 2>&1 && rm -f /.rootfs-write-probe'" 2>&1)"
        if printf '%s' "$probe_out" | grep -q "Read-only file system"; then
            it_pass "read-only rootfs rejects writes with EROFS on $svc (#377)"
        else
            it_fail "read-only rootfs rejects writes with EROFS on $svc (#377)" \
                "expected 'Read-only file system', got: ${probe_out:-<write SUCCEEDED — rootfs is writable>}"
        fi
    done

    # 2. The onion is reachable from OUTSIDE (privacy surface, #343/#360) and SURVIVES the #424 heal
    #    action. An independent external Tor client (its own image/tor/circuits) fetches the dashboard
    #    onion over the real Tor network — no stack SOCKS or plumbing involved. First a baseline; then
    #    we restart tor (the heal's action — the stuck-guard TRIGGER is guard-selection luck and not
    #    reproducible) and assert the onion comes back, proving tor rebuilt circuits + republished its
    #    descriptor. Gated on the baseline so a genuinely-bad live Tor network can't false-fail the
    #    gate: recovery is only asserted when the onion was reachable to begin with.
    #    (Reachability is INBOUND; the clearnet-EXIT half of #424 is not externally observable and
    #    stays with the doctor egress check, which is the stack self-checking its own egress.)
    local pre_onion=0
    if [ "$(env_on_box DASHBOARD_ONION_ADDRESS)" = "placeholder" ] || [ -z "$(env_on_box DASHBOARD_ONION_ADDRESS)" ]; then
        it_skip_leg "dashboard onion external reachability (#424/#343)" "onion not provisioned on this box"
    else
        it_step "external Tor client: reach the dashboard onion before the restart (baseline)…"
        _onion_reachable_external && pre_onion=1
        if [ "$pre_onion" = "1" ]; then
            it_pass "dashboard onion reachable from an independent external Tor client (#343/#360)"
        else
            it_skip_leg "dashboard onion post-restart recovery (#424)" "onion not reachable from outside before the restart (live Tor network) — can't prove recovery"
        fi
        it_step "restart tor (the #424 heal action)…"
        pithead restart tor >/dev/null 2>&1
        wait_status_ok 240 || true
        pithead status >/dev/null 2>&1
        assert_rc "stack healthy after a tor restart (#424 heal action)" "$?" "0"
        if [ "$pre_onion" = "1" ]; then
            it_step "external Tor client: dashboard onion must come back after the restart…"
            if _onion_reachable_external; then
                it_pass "dashboard onion reachable from outside AFTER the tor restart (#424 recovery)"
            else
                it_fail "dashboard onion reachable from outside AFTER the tor restart (#424 recovery)" "external client could not reach the onion within the probe window"
            fi
        fi
    fi

    # 3. The #33 control channel end-to-end THROUGH THE REAL SYSTEMD PATH UNIT. Tier-1 runs
    #    control-run-pending by hand; only here does pithead-control.path actually fire on a spooled
    #    file. Needs a dashboard password (control refuses to enable without one). Enable control,
    #    let apply install + enable the unit, then drop requests and let systemd act.
    local ctrl_config
    ctrl_config="$(printf '%s' "$BASELINE_CONFIG" | jq '.dashboard.secure=true | .dashboard.auth={username:"admin",password:"a tier4 control passphrase"} | .dashboard.control={enabled:true}')"
    push_config "$ctrl_config"
    it_step "apply with dashboard.control enabled (installs the systemd path unit)…"
    pithead apply -y >/dev/null 2>&1
    wait_status_ok 180 || true
    if rx "systemctl is-enabled pithead-control.path >/dev/null 2>&1"; then
        it_pass "pithead-control.path installed + enabled by apply (#33)"
    else
        it_fail "pithead-control.path installed + enabled by apply (#33)" "unit not enabled"
    fi
    # The unit names are box-global, so on a bench that also hosts a live stack the assertion above
    # was already true before this phase ran — the LIVE install's units satisfy it, and it stays
    # green even if our apply installed nothing at all. That is why #1085 went unnoticed for two
    # releases. Bind it to the ExecStart instead: after our apply the units must name THIS checkout,
    # in the exact line provision_control_runner writes. Physical path on both sides (pithead cd -P's
    # to SCRIPT_DIR, rx runs in the checkout), so `current` vs a versioned dir cannot cry wolf.
    assert_contains "the enabled control units name THIS checkout, not another install (#1085)" \
        "$(rx "grep -m1 '^ExecStart=' /etc/systemd/system/pithead-control.service 2>/dev/null" || true)" \
        "ExecStart=$(rx 'pwd -P')/pithead control-run-pending"

    local cdir
    cdir="$(env_on_box CONTROL_DIR)"
    if [ -z "$cdir" ]; then
        it_skip_leg "control spool round-trips" "CONTROL_DIR not set on the box"
    else
        # 3a. A NON-sensitive change (an allowlisted alert toggle) committed via the spool must be
        #     applied BY THE PATH UNIT — not by us calling control-run-pending.
        # Use an allowlisted key that renders UNCONDITIONALLY: DASHBOARD_CHECK_UPDATES is always
        # emitted (a telegram event toggle only renders when telegram is configured, so it reads
        # empty on a telegram-off baseline — a test-only pitfall, not a control-channel bug).
        # A FRESH id per round-trip, exactly as the real dashboard mints one (control_service.submit:
        # str(uuid4())) and NEVER reuses it. A hardcoded id reused across runs collides with the
        # results/ that pithead never sweeps, so the preview's "wait for any status" reads a STALE
        # "applied" left by a prior run's commit and the test races on to the commit before the runner
        # has staged THIS config. A per-run id has no result on disk, so the wait proves the new request.
        local uuid_ok ok_cfg st
        uuid_ok="$(_uuid4)"
        ok_cfg="$(printf '%s' "$ctrl_config" | jq -c '.dashboard.check_for_updates=false')"
        _spool_write "$cdir/requests/$uuid_ok.json" \
            "$(printf '%s' "$ok_cfg" | jq -c --arg id "$uuid_ok" '{id:$id,action:"preview",actor:"itest",config:.}')"
        # Wait for THIS preview to reach "previewed" before committing — mirrors production, where the
        # preview HTTP handler awaits its result and only then does the browser POST the commit. It also
        # confirms the runner CLAIMED the request (drained requests/), so the commit write below is a
        # clean empty→match edge for the path unit instead of racing an unclaimed preview file.
        st="$(_wait_control_status "$cdir" "$uuid_ok" "" 60 || echo timeout)"
        if [ "$st" = "previewed" ]; then
            it_pass "systemd path unit fired + staged a spooled preview (#33) [preview=$st]"
        else
            it_fail "systemd path unit fired + staged a spooled preview (#33)" "preview status=$st (expected previewed)"
        fi
        _spool_write "$cdir/requests/$uuid_ok.json" \
            "$(jq -nc --arg id "$uuid_ok" '{id:$id,action:"commit",actor:"itest"}')"
        st="$(_wait_control_status "$cdir" "$uuid_ok" "previewed" 90 || echo timeout)"
        assert_eq "spool commit applied by the path unit (#33)" "$st" "applied"
        assert_eq "the allowlisted change landed host-side (#33)" "$(env_on_box DASHBOARD_CHECK_UPDATES)" "false"
        assert_contains "control mutation audited (#33)" \
            "$(rx "cat $(quote_arg "$cdir/audit/control.log") 2>/dev/null")" '"action":"commit"'

        # 3b. A SENSITIVE change (wallet swap) MUST be refused host-side, .env untouched — the
        #     Use a checksum-valid fixture so this reaches approval, not address validation.
        local uuid_bad bad_cfg wallet_before
        uuid_bad="$(_uuid4)"
        wallet_before="$(env_on_box MONERO_WALLET_ADDRESS)"
        bad_cfg="$(printf '%s' "$ctrl_config" | jq -c '.monero.wallet_address="44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"')"
        _spool_write "$cdir/requests/$uuid_bad.json" \
            "$(printf '%s' "$bad_cfg" | jq -c --arg id "$uuid_bad" '{id:$id,action:"preview",actor:"itest",config:.}')"
        st="$(_wait_control_status "$cdir" "$uuid_bad" "" 60 || echo timeout)"
        assert_eq "sensitive (wallet) spool preview staged host-side (#33)" "$st" "previewed"
        _spool_write "$cdir/requests/$uuid_bad.json" \
            "$(jq -nc --arg id "$uuid_bad" '{id:$id,action:"commit",actor:"itest"}')"
        st="$(_wait_control_status "$cdir" "$uuid_bad" "previewed" 90 || echo timeout)"
        assert_eq "sensitive (wallet) spool commit refused host-side (#33)" "$st" "rejected"
        assert_eq "refused wallet change did NOT touch .env (#33)" "$(env_on_box MONERO_WALLET_ADDRESS)" "$wallet_before"
    fi

    # Restore the baseline ourselves: re-applying with control off uninstalls the path unit, so the
    # root systemd unit never outlives the phase even though the end-of-run restore would also do it.
    it_step "restoring baseline (disables control, removes the path unit)…"
    push_config "$BASELINE_CONFIG"
    pithead apply -y >/dev/null 2>&1
    # 240s: this apply follows the control enable/disable + a tor restart, so the stack has more to
    # re-settle than a plain apply (180s timed out here on a real run).
    wait_status_ok 240 || true
    # #477: reap the control units unconditionally — the restore apply above is supposed to remove them,
    # but if it died before provision_control_runner ran, the ROOT path unit would linger past the phase.
    # (develop's #424 added a fire-and-forget inline version here; this supersedes it — it verifies the
    # units are actually gone and warns loudly if not, rather than swallowing the outcome with `|| true`.)
    if _remove_control_units; then
        it_pass "control systemd units removed after the hardening phase (#477)"
    else
        it_warn "pithead-control units survived teardown — remove them by hand on the box (sudo unavailable?)"
    fi
}

run_auth_fail_closed() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="auth-fail-closed"
    echo ""
    it_log "── fail-closed auth phase (#153/#203) ──────────────"

    local orig
    orig="$(env_on_box PROXY_AUTH_TOKEN)"
    if [ -z "$orig" ]; then
        it_skip_leg "proxy auth fail-closed" "PROXY_AUTH_TOKEN already empty on the box (run 'pithead setup'/'apply' first)"
        return 0
    fi

    local fails_before="$IT_FAIL"

    # 1. Empty the token; `pithead up` must refuse to start AND name the documented fix.
    it_step "emptying PROXY_AUTH_TOKEN in .env and running 'pithead up'…"
    _set_env_token ""
    local out rc
    out="$(pithead up 2>&1)"
    rc=$?
    assert_ne "pithead up fails closed (non-zero exit) on an empty PROXY_AUTH_TOKEN" "$rc" "0"
    assert_contains "compose guard refuses the unauthenticated proxy API (#153)" \
        "$out" "refusing to start an unauthenticated xmrig-proxy control API"

    # 2. Restore the EXACT original token (apply would mint a new one) and recover.
    it_step "restoring the original PROXY_AUTH_TOKEN and recovering…"
    _set_env_token "$orig"
    assert_eq "original PROXY_AUTH_TOKEN restored verbatim" "$(env_on_box PROXY_AUTH_TOKEN)" "$orig"
    pithead up >/dev/null 2>&1 || it_warn "recovery 'pithead up' returned non-zero; check the box."
    wait_status_ok 240 || true
    pithead status >/dev/null 2>&1
    assert_rc "stack healthy again after token restore" "$?" "0"

    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "auth-fail-closed" "$OUT_DIR"
}

# --- Safety backup / rollback (--safety-backup) -----------------------------
# Take a real `pithead backup` before the destructive scenarios so a failed run can be rolled
# all the way back (config, .env, Caddyfile, Tor onion keys, dashboard DB). This both protects
# a precious box AND exercises backup/restore end-to-end (#102) — closing that CLI-breadth gap.
