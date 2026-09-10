# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_update() {
    info "phase: update (A/B commit + rollback, driven over test-only SSH)"
    # NO local _ssh/_wait_ssh redefinitions here. Function definitions are global but locals are
    # not: a redefinition capturing a local outlives the phase, and the NEXT phase in an
    # --phase all run then calls it with the variable gone — an unbound-variable crash that no
    # standalone phase run can ever reproduce. The top-level helpers already do this job.
    local ip="" marker bundle menu_mark menu_verdict

    info "building v1 test image (test SSH key + marker v1)"
    local img
    img=$(_build_image v1) || {
        bad "v1 test image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 240 ||
        {
            bad "v1 test guest never answered SSH (ip: ${ip:-none})"
            return
        }
    ok "v1 test image boots and answers test SSH ($ip)"
    # #894/#895 baseline, compared after the committed A/B swap below (leg 2) proves SURVIVAL,
    # not mere presence — /data (where both identities live) is untouched by a slot swap.
    local id_v1 hostkey_fp_v1
    id_v1=$(_ssh cat /etc/machine-id)
    hostkey_fp_v1=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    [ "$(_ssh cat /etc/pithead-test-marker)" = "v1" ] && ok "marker v1 on the initial slot" ||
        {
            bad "marker v1 missing on the initial slot"
            return
        }
    # Baseline for the stale-container check below: the v1 image must serve its own marker
    # BEFORE any update, or a later "v2 never served" says nothing about staleness.
    local dm
    if dm=$(_dash_marker_served v1 300); then
        ok "the served page comes from the v1 dashboard image"
    else
        bad "the v1 dashboard image never served its marker (got: $dm)"
        return
    fi

    # #784: /data must fit the MACHINE, not the image. The image ships ~9 GiB with no data
    # partition at all; systemd-repart creates it on the target disk at first boot. The harness
    # grows the scratch disk to 40 GiB, so a correct grow leaves /data well above 15 GiB — an
    # image-sized or unresized /data would land near zero and is the bug this asserts against.
    local data_gib
    data_gib=$(_ssh "df -BG --output=size /data 2>/dev/null | tail -1 | tr -dc '0-9'")
    if [ -n "$data_gib" ] && [ "$data_gib" -ge 15 ]; then
        ok "/data grew to fill the disk (${data_gib} GiB of a 40 GiB disk)"
    else
        bad "/data did not grow to fill the disk (got '${data_gib:-none}' GiB, want >= 15)"
    fi
    # The slots must NOT have grown — an A/B pair has to stay interchangeable.
    local slot_gib
    slot_gib=$(_ssh "df -BG --output=size / 2>/dev/null | tail -1 | tr -dc '0-9'")
    if [ -n "$slot_gib" ] && [ "$slot_gib" -le 5 ]; then
        ok "system slot stayed fixed at ${slot_gib} GiB"
    else
        bad "system slot grew to '${slot_gib:-none}' GiB — slots must stay interchangeable"
    fi

    info "building v2 update bundle (marker v2)"
    bundle=$(_build_bundle v2) || {
        bad "v2 bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    [ -n "$bundle" ] || {
        bad "no update bundle produced"
        return
    }
    ok "built v2 bundle: $(basename "$bundle")"

    # Install failures MUST be surfaced. Both candidates failed silently for several rounds
    # because the install was fired with `|| true` and only the marker was checked afterwards —
    # the harness reported "update did not take" when the real story was "install never ran".
    _install_or_fail() { # $1 human label
        local out
        out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1")
        local rc=$?
        [ -n "$out" ] && printf '     install output (%s): %s\n' "$1" "$(printf '%s' "$out" | tail -5)"
        return $rc
    }

    info "leg 1 — install v2, boot spare, reboot WITHOUT commit -> must fall back to v1"
    _stage_bundle "$bundle" || {
        bad "staging the bundle on the guest failed"
        return
    }
    _install_or_fail "leg 1" || {
        bad "the v2 install command failed on the guest"
        return
    }
    ok "v2 installed into the spare slot"
    _reboot_wait "$(_boot_spare_cmd)" 300 || {
        bad "guest never returned after booting the spare slot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "spare slot booted with v2" || {
        bad "expected v2 in the spare slot, got '$marker'"
        return
    }
    _reboot_wait reboot 300 || { # uncommitted -> the bootloader must fall back on its own
        bad "guest never returned after the no-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v1" ] && ok "ROLLBACK: an uncommitted update reverts to v1 on reboot" || {
        bad "expected v1 after the uncommitted reboot, got '$marker'"
        return
    }

    info "leg 2 — install v2 again, COMMIT, reboot -> must stay v2"
    _install_or_fail "leg 2" || {
        bad "the second v2 install failed on the guest"
        return
    }
    _reboot_wait "$(_boot_spare_cmd)" 300 || {
        bad "guest never returned after the second install"
        return
    }
    _ssh "$(_commit_cmd)" || {
        bad "commit failed ($(_commit_cmd))"
        return
    }
    ok "committed the booted update"
    menu_mark=$(wc -c <"$SERIAL" 2>/dev/null | tr -d ' ')
    _reboot_wait reboot 300 || {
        bad "guest never returned after the post-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "COMMIT: a committed update persists across reboot" ||
        bad "expected v2 after commit, got '$marker'"
    menu_verdict=$(boot_label_serial_verdict "$SERIAL" "$menu_mark" "$(tr -d '[:space:]' <VERSION)" B A) && ok "$menu_verdict" || bad "$menu_verdict"
    # #894/#895: host identity on /data must survive the system-slot swap.
    local id_v2 hostkey_fp_v2
    id_v2=$(_ssh cat /etc/machine-id)
    hostkey_fp_v2=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    if [ -n "$id_v1" ] && [ "$id_v1" = "$id_v2" ]; then
        ok "machine-id survived the A/B swap ($id_v1)"
    else
        bad "machine-id changed across the A/B swap (v1: ${id_v1:-none}, v2: ${id_v2:-none})"
    fi
    if [ -n "$hostkey_fp_v1" ] && [ "$hostkey_fp_v1" = "$hostkey_fp_v2" ]; then
        ok "SSH host-key fingerprint survived the A/B swap ($hostkey_fp_v1)"
    else
        bad "SSH host-key fingerprint changed across the A/B swap (v1: ${hostkey_fp_v1:-none}, v2: ${hostkey_fp_v2:-none})"
    fi
    # THE stale-container assertion: the OS slot saying v2 is not enough — an A/B update that
    # ships a new dashboard must end with the NEW image answering, without any wizard
    # involvement. The tag never changes and podman's store survives on /data, so only the
    # boot-path loader can make this true.
    if dm=$(_dash_marker_served v2 360); then
        ok "UPDATE REFRESHED THE CONTAINERS: the served page comes from the v2 dashboard image"
    else
        bad "the OS updated to v2 but the served page still comes from the old dashboard image (got: $dm)"
    fi

    info "leg 3 — operator-initiated rollback off a committed update"
    # Mark the serial BEFORE issuing the reboot that leg 4 provisions against: neither
    # config.json nor machine-role ever gets written by legs 1-3 (they only drive rauc), so
    # pithead-firstboot's ConditionPathExists stays satisfied and every one of the five reboots
    # above re-ran the wizard and minted its own token, none of them flushed by
    # _vm_boot_disk's one-time truncate (before leg 1). Taking the mark here — not on
    # entry to _wizard_provision_capture — is what makes it safe: anything already on the
    # serial before this point is a dead token from an earlier, now-destroyed wizard container,
    # and everything after belongs to the boot leg 4 actually runs against.
    local serial_mark
    serial_mark=$(wc -c <"$SERIAL" 2>/dev/null | tr -d ' ')
    _reboot_wait "$(_rollback_cmd)" 300 || {
        bad "guest never returned after an operator rollback"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v1" ] && ok "ROLLBACK: an operator can return to v1 after committing v2" ||
        bad "expected v1 after the operator rollback, got '$marker'"

    phase_update_dashboard "$bundle" "${serial_mark:-0}"
}

# Provision the wizard-gated stack over its real HTTP flow — the slim shape of what
# phase_provision drives with full assertions — and CAPTURE the generated dashboard login for
# API-driving legs. Sets DASH_USER/DASH_PASS. rc 1 on any failure; WIZ_FAIL_REASON names which of
# the six gates lost (the caller reports it — "no dashboard, no control channel" used to be the
# whole story, and every diagnostic run since has cost a battery pass to learn nothing more).
DASH_USER=""
DASH_PASS=""
WIZ_FAIL_REASON=""
_wizard_provision_capture() { # <serial-byte-offset-before-this-boot, default 0>
    local mark="${1:-0}" token="" tries=0 jar scode handoff="" tok_total
    WIZ_FAIL_REASON=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        # Only the tail past $mark: content from before this boot is a dead token from an
        # earlier, now-destroyed wizard container (see the leg-3 comment on serial_mark).
        token=$(tail -c "+$((mark + 1))" "$SERIAL" 2>/dev/null | tr -d '\r' | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    if [ -z "$token" ]; then
        WIZ_FAIL_REASON="gate: token — no pit-XXXXXX ever appeared on the serial console for this boot (waited ${tries}x3s)"
        return 1
    fi
    if ! _wait_setup_page 180; then
        WIZ_FAIL_REASON="gate: setup page — https://$ip/ never answered 'Pithead setup' within 180s (token: $token)"
        return 1
    fi
    jar=$(mktemp)
    if ! curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null; then
        # The number that confirms or kills the stale-token theory in one run: how many DISTINCT
        # tokens the whole serial (not just this boot's slice) is carrying right now.
        tok_total=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | sort -u | wc -l | tr -d ' ')
        WIZ_FAIL_REASON="gate: auth POST — https://$ip/auth rejected token $token ($tok_total distinct pit- token(s) on the serial so far)"
        rm -f "$jar"
        return 1
    fi
    if ! grep -q "wizard_session" "$jar"; then
        WIZ_FAIL_REASON="gate: session cookie — /auth returned 200 but set no wizard_session cookie (token: $token)"
        rm -f "$jar"
        return 1
    fi
    scode=$(curl -sSk -b "$jar" --data "monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    if [ "$scode" != "200" ]; then
        WIZ_FAIL_REASON="gate: submit — /submit returned $scode, want 200"
        rm -f "$jar"
        return 1
    fi
    tries=0
    while [ "$tries" -lt 24 ]; do
        handoff=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$handoff" | grep -q '"password"' && break
        sleep 5
        tries=$((tries + 1))
    done
    if ! printf '%s' "$handoff" | grep -q '"password"'; then
        WIZ_FAIL_REASON="gate: handoff — /api/handoff never carried a password (waited ${tries}x5s)"
        rm -f "$jar"
        return 1
    fi
    DASH_USER=$(printf '%s' "$handoff" | jq -r '.username // "admin"')
    DASH_PASS=$(printf '%s' "$handoff" | jq -r '.password // ""')
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    [ -n "$DASH_PASS" ] || WIZ_FAIL_REASON="gate: handoff — password came back empty"
    [ -n "$DASH_PASS" ]
}

# POST one dashboard OS-update step and wait out its terminal result (progress statuses are
# in-flight, not terminal). Echoes the final result JSON; rc 1 on transport failure/deadline.
_os_step() { # <json-body> [<deadline-s>]
    local body="$1" deadline=$(($(date +%s) + ${2:-180})) rid out st
    rid=$(curl -sSk -u "$DASH_USER:$DASH_PASS" -H 'Content-Type: application/json' \
        -H 'X-Pithead-Control: 1' --data "$body" "https://$ip/api/control/os-update" 2>/dev/null |
        jq -r '.id // ""')
    [ -n "$rid" ] || return 1
    while [ "$(date +%s)" -lt "$deadline" ]; do
        out=$(curl -sSk -u "$DASH_USER:$DASH_PASS" "https://$ip/api/control/result?id=$rid" 2>/dev/null)
        st=$(printf '%s' "$out" | jq -r '.status // "pending"' 2>/dev/null) || st="pending"
        case "$st" in
        pending | running | downloading | installing | "") sleep 3 ;;
        *)
            printf '%s' "$out"
            return 0
            ;;
        esac
    done
    return 1
}

# Serve a directory over HTTP with byte-range support (curl -C - needs 206; python's stock
# SimpleHTTPRequestHandler answers 200-only, which would silently break the resume leg).
# Echoes the server PID; caller kills it.
# <dir> <port> [probe-file] -> prints the pid; rc 1 if the port never actually answered.
#
# The probe is the point (#1149). This used to background python with `>/dev/null 2>&1` and print
# `$!` unconditionally, so a FAILED BIND reported a running server: the error went to /dev/null and
# `$!` is a pid whether or not the process survived. A leaked server from an aborted run is the
# normal case on a bench — every failure path below kills `$srv_pid`, which is already dead when
# the bind failed, and `--keep` skips the kill entirely — and that corpse is serving a directory
# the previous run has since `rm -rf`'d, so every request 404s. The guest then got a 404 where it
# expected the release JSON, `curl -fsS` reported it the same as a dead circuit, and leg 4 blamed
# Tor for three sessions.
#
# The custom handler below 404s on a directory, so the probe names a real file — the one the
# caller has already written before starting the server.
_serve_update_dir() { # <dir> <port>
    python3 - "$1" "$2" <<'PYEOF' >/dev/null 2>&1 &
import http.server, os, re, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        path = self.translate_path(self.path)
        # Independent witness for the resume leg (#1051): the product's own `resumed_from`
        # field is the size of the partial file it staged BEFORE curl ever ran, so it holds
        # whether or not curl actually resumed — it cannot catch a resume that silently
        # restarted from zero. This log records what the server itself received on the wire,
        # which is the one place that can.
        with open(os.path.join(sys.argv[1], ".requests.log"), "a") as _lf:
            _lf.write(f"{os.path.basename(path)} {self.headers.get('Range') or 'none'}\n")
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start = 0
        m = re.match(r"bytes=(\d+)-$", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1))
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        else:
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size - start))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except BrokenPipeError:
                    break
http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[2])), H).serve_forever()
PYEOF
    local pid=$! i
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    for i in $(seq 40); do
        if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$2/releases-latest.json" 2>/dev/null; then
            printf '%s' "$pid"
            return 0
        fi
        sleep 0.25
    done
    # It never answered. Say WHO holds the port — a leftover from an earlier run is the usual
    # answer, and without this line the next person debugs the guest instead of the bench.
    # STDERR, not stdout: this function's stdout IS the pid, so the caller reads it through a
    # command substitution — an `info` here would be captured into the variable and never seen.
    # Same shape as the swallowed hint in #1081; the diagnostic has to step outside the capture.
    info "bench update server never answered on :$2 — port holder: $(ss -ltnp "sport = :$2" 2>/dev/null | tail -n +2 | tr -s ' ' | cut -c1-160)" >&2
    kill "$pid" 2>/dev/null
    return 1
}

# Leg 4 — the dashboard OS-update action end-to-end: the user-reachable path over the SAME A/B
# machinery legs 1-3 proved raw. Provisions the stack (the control channel and dashboard exist
# only on a provisioned machine), then drives check → download (with a proven RESUME) → verify
# (with the floor and bad-signature refusals) → install → the explicit reboot intent → the
# boot-gated commit → the persisted verdict the dashboard renders. The release lookup and the
# bundle download are pointed at a bench-local server through the root-owned test seam
# (os-update-test-base); RAUC signature verification still runs for real against the slot
# keyring, so the bad-signature refusal is genuine, not simulated.
_leg4_srv_stop() { # the bench release server and its dir, torn down at every leg-4 exit; reads the caller's locals
    # shellcheck disable=SC2154  # shared through the assembled runner scope
    kill "$srv_pid" 2>/dev/null
    # shellcheck disable=SC2154  # shared through the assembled runner scope
    rm -rf "$srv"
}
