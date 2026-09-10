# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
fault_node_down() {
    if wait_for 180 5 "dashboard to observe monerod before failover fault" _pred_failover_armed; then
        it_pass "node-down failover armed from a live monerod observation"
    else
        it_fail "node-down failover armed before fault" "dashboard never reported reachable monerod with the miner released and proxy admitted — fault not injected"
        return
    fi
    it_step "fault: stop monerod (required node down)…"
    rx "docker compose stop monerod" >/dev/null 2>&1
    wait_for 60 5 "status to report a problem" _pred_status_down || true
    pithead status >/dev/null 2>&1
    assert_rc "status non-zero when monerod is down" "$?" "1"
    # After the node-health debounce, stopping xmrig-proxy sends workers to backup pools (#31).
    wait_for 180 10 "xmrig-proxy stopped by failover" _pred_proxy_stopped || true
    assert_eq "xmrig-proxy stopped for failover" "$(svc_state_of "$(service_state xmrig-proxy)")" "exited"
    it_step "recover: start monerod…"
    rx "docker compose start monerod" >/dev/null 2>&1
    wait_for 240 5 "monerod healthy" _pred_monerod_healthy || true
    wait_status_ok 240 || true
    pithead status >/dev/null 2>&1
    assert_rc "status OK after monerod recovery" "$?" "0"
}

fault_unhealthy() {
    it_step "fault: freeze monerod (SIGSTOP) so its healthcheck fails…"
    rx "docker compose kill -s SIGSTOP monerod" >/dev/null 2>&1
    # The get_info healthcheck now times out; after its retries the container flips to
    # running-but-unhealthy — the verdict stack_status flags as a problem.
    wait_for 200 10 "monerod to report unhealthy" _pred_monerod_unhealthy || true
    assert_eq "monerod running-but-unhealthy" "$(service_state monerod)" "running unhealthy"
    pithead status >/dev/null 2>&1
    assert_rc "status non-zero when monerod unhealthy" "$?" "1"
    it_step "recover: thaw monerod (SIGCONT)…"
    rx "docker compose kill -s SIGCONT monerod" >/dev/null 2>&1
    wait_for 120 5 "monerod healthy" _pred_monerod_healthy || true
}

fault_missing() {
    it_step "fault: remove the monerod container…"
    rx "docker compose rm -sf monerod" >/dev/null 2>&1
    wait_for 30 3 "monerod to be missing" _pred_monerod_missing || true
    assert_eq "monerod reported missing" "$(svc_state_of "$(service_state monerod)")" "missing"
    pithead status >/dev/null 2>&1
    assert_rc "status non-zero when monerod missing" "$?" "1"
    it_step "recover: recreate monerod…"
    rx "docker compose up -d monerod" >/dev/null 2>&1
    wait_for 240 5 "monerod healthy" _pred_monerod_healthy || true
}

# Live counterpart to the tier-1 #131 flag-logic tests: make the dashboard's data dir read-only on
# the REAL filesystem and prove /api/state flags db_healthy:false while the dashboard keeps serving,
# then restore write access and prove recovery (#202). Two facts dictate the restarts: chmod cannot
# fail writes on already-open file descriptors (the dashboard holds a live sqlite connection with
# WAL/shm sidecars open), so the fault only trips when a fresh process re-runs _init_db; and
# db_healthy is a one-way latch per process (storage_service only sets it True in __init__), so
# recovery needs a fresh process too — a successful write can't clear the flag.
fault_db_readonly() {
    local ddir
    ddir="$(env_on_box DASHBOARD_DATA_DIR)"
    if [ -z "$ddir" ]; then
        it_skip_leg "db-readonly fault" "no DASHBOARD_DATA_DIR in .env"
        return 0
    fi
    it_step "fault: make the dashboard data dir read-only (#131/#202)…"
    # The data dir is uid-1000-owned (#255) and the deploy user usually isn't uid 1000, so both
    # chmods need sudo (already an assumed capability: fault_firewall_rollback uses it). -R covers
    # the -wal/-shm sidecar files too.
    rx "sudo chmod -R a-w $(quote_arg "$ddir")" >/dev/null 2>&1
    rx "docker compose restart dashboard" >/dev/null 2>&1
    wait_for 90 5 "dashboard to report db_healthy=false" _pred_db_healthy_is false || true
    # api_state answering at all is part of the assertion: the #131 design keeps the web server
    # serving (reads still work) while persistence is broken.
    assert_eq "db_healthy false while data dir is read-only" \
        "$(jq_get "$(api_state)" '.db_healthy')" "false"
    it_step "recover: restore write access and restart the dashboard…"
    rx "sudo chmod -R u+w $(quote_arg "$ddir")" >/dev/null 2>&1
    rx "docker compose restart dashboard" >/dev/null 2>&1
    wait_for 90 5 "dashboard to report db_healthy=true" _pred_db_healthy_is true || true
    assert_eq "db_healthy true after write access restored" \
        "$(jq_get "$(api_state)" '.db_healthy')" "true"
}

# Live counterpart to the tier-1 stubbed rollback (tests/stack/run.sh #270): force a REAL
# `iptables -I` to fail mid-apply and prove the box ends fail-closed — the partial ruleset is
# rolled BACK, not left half-open (a stubbed iptables can't prove the real kernel strips a partial
# insert). DESTRUCTIVE-then-restored: apply_tor_egress_firewall clears the live rules before
# re-inserting, so on the sabotaged run the firewall is briefly down until the recover step (and
# run_fault_injection's belt-and-braces) reinstate it — hence opt-in, local-box only.
fault_firewall_rollback() {
    if [ "$(env_on_box TOR_EGRESS_FIREWALL)" = "false" ]; then
        it_skip_leg "firewall-rollback fault" "network.tor_egress_firewall=false"
        return 0
    fi
    it_step "fault: force an iptables -I failure during the firewall apply…"
    # Shadow SUDO (not iptables): apply calls `sudo iptables -I`, and sudo's secure_path ignores a
    # PATH-shadowed iptables, so the insert would really succeed. sudo itself is still found via PATH,
    # so a wrapper that fails an `iptables … -I …` insert and execs real sudo for everything else
    # (remove's -D, -N, iptables-save) makes the insert fail exactly as a real mid-insert error would.
    # On PATH only for the apply below, deleted on recover. $realsudo baked at write time; \$1/\$a/\$@
    # stay literal. (Verified live on a real box — the iptables-shadow variant silently no-ops.)
    rx 'realsudo=$(command -v sudo) && mkdir -p .itest-bin && printf "%s\n" "#!/usr/bin/env bash" "if [ \"\$1\" = iptables ]; then for a; do [ \"\$a\" = -I ] && exit 1; done; fi" "exec $realsudo \"\$@\"" > .itest-bin/sudo && chmod +x .itest-bin/sudo' >/dev/null 2>&1
    # apply_tor_egress_firewall is a pithead function (main is guarded when sourced), so sourcing +
    # calling it with the sabotaged iptables hits the exact rollback branch.
    local rc
    rx 'PATH="$PWD/.itest-bin:$PATH" bash -c "source ./pithead && apply_tor_egress_firewall" >/dev/null 2>&1'
    rc=$?
    assert_rc "firewall apply degrades gracefully on an insert failure (rc 0)" "$rc" "0"
    # No pithead-tagged rule may survive a failed insert — the rollback must strip the partial set.
    assert_eq "insert failure leaves NO half-open firewall (rolled back)" \
        "$(rx 'sudo iptables-save 2>/dev/null | grep -c pithead-tor-egress')" "0"
    it_step "recover: drop the sabotage and reinstall the real firewall…"
    rx 'rm -rf .itest-bin' >/dev/null 2>&1
    rx 'bash -c "source ./pithead && apply_tor_egress_firewall" >/dev/null 2>&1' || true
    assert_num_gt "firewall reinstated after recovery" \
        "$(rx 'sudo iptables-save 2>/dev/null | grep -c pithead-tor-egress')" 0
}

# TOP PRIVACY PRIORITY (#563): stop the tor container — the SOCKS proxy every app dials through
# (#270) — and prove two things a healthy-box run never exercises: (a) nothing falls back to a
# direct clearnet dial while SOCKS is unreachable (reuses assert_egress_posture, the same
# /proc/net/tcp proof the steady-state battery runs, now during the one window it's never been
# live-checked: SOCKS itself down), and (b) `doctor` names the outage rather than staying quiet —
# today check_egress_firewall_installed and check_tor_clearnet_egress both SKIP (dr_info, not
# dr_fail/dr_warn) once the tor container isn't running, so a doctor run with everything else
# healthy can print "All checks passed." while the whole privacy backbone is gone. Local mode only
# (needs a local tor container to break).
fault_tor_down() {
    it_step "fault: stop the tor container — SOCKS unreachable (#563)…"
    rx "docker compose stop tor" >/dev/null 2>&1
    wait_for 30 3 "tor to be stopped" _pred_tor_stopped || true
    assert_eq "tor reported stopped" "$(svc_state_of "$(service_state tor)")" "exited"

    # (a) No clearnet egress leak while the Tor SOCKS is unreachable. Tor is stopped ON PURPOSE
    # here, so its own relay-count positive control cannot hold — waive it explicitly, or the
    # verifier reports INCONCLUSIVE and this privacy check reads as tooling breakage forever.
    assert_egress_posture tor-down

    # (b) doctor must FLAG the outage loudly, not pass silently.
    local doc rc
    doc="$(pithead doctor 2>&1)"
    rc=$?
    assert_ne "doctor exits non-zero while the tor container is down — loud failure, not silence (#563)" "$rc" "0"
    case "$doc" in
    *"All checks passed."*)
        it_fail "doctor does not silently report all-clear with tor down (#563)" \
            "doctor printed 'All checks passed.' while the tor container was stopped"
        ;;
    *) it_pass "doctor does not silently report all-clear with tor down (#563)" ;;
    esac

    it_step "recover: start tor…"
    rx "docker compose start tor" >/dev/null 2>&1
    wait_for 180 5 "tor healthy" _pred_tor_healthy || true
    wait_status_ok 180 || true
    pithead status >/dev/null 2>&1
    assert_rc "status OK after tor recovery" "$?" "0"
    # Recovery isn't just "container up" — a flapping SOCKS during reconnect is exactly when a
    # leak would show, so re-run the same egress proof once Tor is back.
    assert_egress_posture
}

# Clock-drift verdict (#383): doctor's NTP check (clock_sync_status, reading `timedatectl show -p
# NTPSynchronized --value`) is unit-tested only against a stubbed timedatectl — never against a
# real doctor run on a real box. Shadowing the timedatectl BINARY (the same PATH-prepend trick
# fault_firewall_rollback uses for sudo) proves the real function reads a real timedatectl's real
# output shape and classifies it correctly end to end, WITHOUT actually skewing the box's clock —
# mining is time-sensitive (P2Pool/Monero reject skewed shares/blocks), so touching the real clock
# on a precious release-gate box is exactly what this harness avoids elsewhere (#54 safety model).
fault_clock_drift() {
    it_step "fault: shadow timedatectl to report NTPSynchronized=no (clock-drift, #383)…"
    rx 'mkdir -p .itest-bin && printf "%s\n" "#!/usr/bin/env bash" "if [ \"\$1\" = show ]; then echo no; fi" > .itest-bin/timedatectl && chmod +x .itest-bin/timedatectl' >/dev/null 2>&1
    local out
    out="$(rx "PATH=\"\$PWD/.itest-bin:\$PATH\" $IT_PITHEAD doctor 2>&1")"
    assert_contains "doctor flags clock skew — NOT NTP-synchronized (#383)" "$out" "NOT NTP-synchronized"
    it_step "recover: drop the timedatectl shadow…"
    rx 'rm -rf .itest-bin' >/dev/null 2>&1
    out="$(pithead doctor 2>&1)"
    assert_eq "doctor's clock-sync verdict no longer flags unsynced once the shadow is gone (#383)" \
        "$(printf '%s' "$out" | grep -c 'NOT NTP-synchronized')" "0"
}

# ENOSPC / db-unhealthy verdict (#383): fault_db_readonly (above) proves the #131 db_healthy flag
# under a PERMISSION failure (chmod a-w); a genuinely FULL disk is a different real failure mode
# (ENOSPC, not EACCES) and is never forced — only a disk-headroom *warning* is checked (doctor's
# check_disk_grouped). A 1MiB tmpfs bind-mounted OVER the dashboard data dir shadows its real
# contents (nothing on the box's actual disk is touched; unmounting restores them) and fills solid,
# so the dashboard's sqlite writes there hit a REAL kernel ENOSPC. Reuses the same db_healthy
# predicate/assertions as fault_db_readonly — the trigger differs, the observable contract doesn't.
fault_disk_enospc() {
    local ddir
    ddir="$(env_on_box DASHBOARD_DATA_DIR)"
    if [ -z "$ddir" ]; then
        it_skip_leg "ENOSPC fault" "no DASHBOARD_DATA_DIR in .env"
        return 0
    fi
    it_step "fault: mount a 1MiB tmpfs over the dashboard data dir and fill it (real ENOSPC, #383)…"
    if ! rx "sudo mount -t tmpfs -o size=1m,uid=1000,gid=1000 tmpfs $(quote_arg "$ddir")" >/dev/null 2>&1; then
        it_skip_leg "ENOSPC fault" "could not mount a tmpfs over the data dir (no root / tmpfs support?)"
        return 0
    fi
    rx "dd if=/dev/zero of=$(quote_arg "$ddir/.itest-fill") bs=1M count=4 >/dev/null 2>&1" >/dev/null 2>&1 || true
    rx "docker compose restart dashboard" >/dev/null 2>&1
    wait_for 90 5 "dashboard to report db_healthy=false under real ENOSPC" _pred_db_healthy_is false || true
    assert_eq "db_healthy false under a real full disk (ENOSPC, #383)" \
        "$(jq_get "$(api_state)" '.db_healthy')" "false"
    it_step "recover: unmount the tmpfs, restoring the real data dir…"
    rx "sudo umount $(quote_arg "$ddir")" >/dev/null 2>&1
    rx "docker compose restart dashboard" >/dev/null 2>&1
    wait_for 90 5 "dashboard to report db_healthy=true after ENOSPC recovery" _pred_db_healthy_is true || true
    assert_eq "db_healthy true after real disk restored" \
        "$(jq_get "$(api_state)" '.db_healthy')" "true"
}

run_fault_injection() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="fault-injection"
    echo ""
    it_log "── fault-injection phase ───────────────────────────"
    if ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_skip_phase "fault-injection" "remote mode: no local monerod to break" "by-design"
        return 0
    fi

    local fails_before="$IT_FAIL"
    fault_node_down
    fault_unhealthy
    fault_missing
    fault_db_readonly
    fault_firewall_rollback
    fault_tor_down
    fault_clock_drift
    fault_disk_enospc
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "fault-injection" "$OUT_DIR"

    # Belt-and-braces: whatever happened above, leave monerod + tor up, the dashboard data dir
    # writable (real fs, not the ENOSPC tmpfs), the firewall reinstated, the timedatectl shadow
    # gone, and the stack healthy — all unconditional so a mid-phase abort can't leave the box
    # read-only, tmpfs-shadowed, clock-shadowed, or with clearnet egress open.
    rx "docker compose up -d monerod" >/dev/null 2>&1 || true
    rx "docker compose up -d tor" >/dev/null 2>&1 || true
    rx "sudo umount $(quote_arg "$(env_on_box DASHBOARD_DATA_DIR)")" >/dev/null 2>&1 || true
    rx "sudo chmod -R u+w $(quote_arg "$(env_on_box DASHBOARD_DATA_DIR)")" >/dev/null 2>&1 || true
    rx "docker compose restart dashboard" >/dev/null 2>&1 || true
    rx 'bash -c "source ./pithead && apply_tor_egress_firewall" >/dev/null 2>&1' || true
    rx 'rm -rf .itest-bin' >/dev/null 2>&1 || true
    wait_for 240 5 "monerod healthy after fault phase" _pred_monerod_healthy || true
    wait_for 240 5 "tor healthy after fault phase" _pred_tor_healthy || true
    wait_status_ok 240 || true
}

# --- Fail-closed auth phase (--auth-fail-closed) ----------------------------
# Live counterpart to the tier-1 compose-config assertion (tests/stack/standalone/test_compose.sh): prove the
# DEPLOY path — not just `docker compose config` — refuses to start an unauthenticated xmrig-proxy
# control API when PROXY_AUTH_TOKEN is empty (#153/#203). We empty the token in .env and run
# `pithead up`, which does NOT re-render .env (only setup/apply do — and apply would self-heal by
# regenerating the token), so the compose `:?` guard fires and the stack refuses to start. The
# `:?` error aborts `docker compose up` before it touches any container, so a running stack is left
# intact. We then restore the EXACT original token (a fresh one would break the run's end-of-run
# secret-fingerprint check) and bring the stack back healthy. DESTRUCTIVE-then-restored.

# Rewrite PROXY_AUTH_TOKEN in .env in place, preserving line order. quote_arg makes the value safe
# for the remote shell; awk leaves every other line untouched.
