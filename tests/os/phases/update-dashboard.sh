# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_update_dashboard() { # <good-bundle-path> <serial-byte-offset-before-this-boot>
    local good_bundle="$1" serial_mark="${2:-0}" marker before
    info "leg 4 — dashboard OS-update action end-to-end (provision, then check/download/verify/install/reboot)"
    if ! _wizard_provision_capture "$serial_mark"; then
        bad "leg 4: could not provision the stack through the wizard (${WIZ_FAIL_REASON:-no dashboard, no control channel})"
        return
    fi
    ok "leg 4: stack provisioned; dashboard login captured"
    # The stack must come up far enough that caddy answers and the control runner exists.
    local deadline=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ok "leg 4: stack containers are running" ;;
    *)
        bad "leg 4: stack never came up — running: '${names:-none}'"
        return
        ;;
    esac
    local tries=0 code=000
    while [ "$tries" -lt 60 ]; do
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
        case "$code" in 2?? | 3?? | 401 | 403) break ;; esac
        sleep 5
        tries=$((tries + 1))
    done
    # The UI-presence contract: an appliance state carries os_update, so the header renders the
    # OS control instead of the tarball Upgrade button.
    if curl -sSk -u "$DASH_USER:$DASH_PASS" "https://$ip/api/state" 2>/dev/null |
        jq -e '.os_update.step' >/dev/null 2>&1; then
        ok "leg 4: /api/state carries the appliance os_update state (the header control renders)"
    else
        bad "leg 4: /api/state has no os_update — the dashboard would never show the OS control"
        return
    fi

    # Bench-local release server: the good v2 bundle plus a corrupted twin, behind the seam.
    local tag srv host_addr port=8931 size srv_pid
    # The tag the bench release server publishes MUST match the bundle's own stamp, which is the
    # checkout's VERSION — the bundle is built from this tree.
    tag="v$(tr -d ' \t\r\n' <VERSION)"
    srv=$(mktemp -d)
    cp "$good_bundle" "$srv/pithead-os-$tag.raucb"
    size=$(wc -c <"$srv/pithead-os-$tag.raucb" | tr -d ' ')
    cp "$srv/pithead-os-$tag.raucb" "$srv/good.raucb"
    cp "$srv/good.raucb" "$srv/bad.raucb"
    # One clobbered byte mid-file: the signature no longer matches, nothing else changes.
    dd if=/dev/zero of="$srv/bad.raucb" bs=1 seek=$((size / 2)) count=64 conv=notrunc 2>/dev/null
    printf '{"tag_name":"%s","html_url":"http://bench.invalid/rel","assets":[{"name":"pithead-os-%s.raucb","size":%s}]}' \
        "$tag" "$tag" "$size" >"$srv/releases-latest.json"
    host_addr=$(ip -4 -o addr show virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$host_addr" ] || host_addr="192.168.122.1"
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    if ! srv_pid=$(_serve_update_dir "$srv" "$port"); then
        bad "leg 4: the bench release server never answered on :$port — nothing was checked, and this is the harness, not the product (#1149)"
        rm -rf "$srv"
        return
    fi
    _ssh "printf 'http://$host_addr:$port' > /data/pithead/os-update-test-base" || {
        bad "leg 4: could not plant the update-server seam on the guest"
        _leg4_srv_stop
        return
    }

    # A real update arrives at a box running something OLDER, and the dashboard door refuses an
    # equal target on purpose: an equal-version reinstall is a forced-downtime and flash-wear loop
    # for a compromised container. Both images here are built from the one checkout, so without
    # this the guest is already running the version the bundle carries and leg 4 could never get
    # past its first download — it reported #976's path as broken while never offering it anything
    # to install. Age the RUNNING side, never the bundle's stamp (see tests/os/aged-version.sh).
    #
    # Safe here specifically: nothing renders .env or runs compose between this write and the
    # reboot — `pithead os-update` is a rauc install — and pithead-sync restores the slot's real
    # VERSION on the next boot, before pithead-boot reads it to judge the update. So the guest
    # claims the older version exactly for the length of the check/download/install window.
    # #1676: a failed precondition here used to cost SEVEN reds — every later step fails on the
    # same un-aged guest — so both failure shapes return after their one red.
    local aged
    if ! aged=$(aged_version "${tag#v}"); then
        bad "leg 4: cannot age the running version ${tag#v} — nothing sorts below it (tests/os/aged-version.sh)"
        _leg4_srv_stop
        return
    fi
    if ! _ssh "printf '%s\n' '$aged' > /data/pithead/VERSION"; then
        bad "leg 4: could not age the guest's running version to $aged"
        _leg4_srv_stop
        return
    fi

    local out st
    # Check: the host derives tag + size from the (redirected) release lookup.
    out=$(_os_step '{"action":"check"}' 120)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "checked" ] &&
        [ "$(printf '%s' "$out" | jq -r '.version')" = "$tag" ]; then
        ok "leg 4: check derived the published release ($tag, $(printf '%s' "$out" | jq -r '.size') bytes)"
    else
        bad "leg 4: check did not derive the release (got: $(printf '%s' "$out" | cut -c1-200))"
        _leg4_srv_stop
        return
    fi

    # Refusal 1 — the /data floor, via the dashboard door onto the SAME guard the CLI enforces. A
    # floor above this (newer) bundle is above the running version too: since #1393 that is the
    # failed-migration state, refused FIRST with its premise; the plain door is tier 1's (#1694).
    _ssh "printf '99.0.0\n' > /data/pithead/.os-data-floor"
    out=$(_os_step "{\"action\":\"download\",\"version\":\"$tag\"}" 900)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "downloaded" ]; then
        ok "leg 4: bundle downloaded to /data for the floor leg"
    else
        bad "leg 4: download for the floor leg did not complete (got: $(printf '%s' "$out" | cut -c1-200))"
    fi
    out=$(_os_step '{"action":"verify"}' 120)
    st=$(printf '%s' "$out" | jq -r '.status')
    if [ "$st" = "rejected" ] && printf '%s' "$out" | jq -r '.error' | grep -q "failed its gate.*the floor version or newer installs"; then
        ok "leg 4: FLOOR ABOVE THE RUNNING VERSION REFUSED — verify refuses with the failed-migration premise and the open route"
    else
        bad "leg 4: verify under a floor above the running version did not refuse with the true premise (got: $(printf '%s' "$out" | cut -c1-200))"
    fi
    if ! _ssh "test -f /data/pithead/data/os-update/pithead-os-$tag.raucb"; then
        ok "leg 4: the floor-refused bundle was deleted"
    else
        bad "leg 4: the floor-refused bundle is still staged"
    fi
    _ssh "rm -f /data/pithead/.os-data-floor"

    # Refusal 2 — a corrupted (mis-signed) bundle: RAUC's real signature check against the slot
    # keyring refuses it, the error says so, and the file is deleted. No override exists.
    cp "$srv/bad.raucb" "$srv/pithead-os-$tag.raucb"
    out=$(_os_step "{\"action\":\"download\",\"version\":\"$tag\"}" 900)
    [ "$(printf '%s' "$out" | jq -r '.status')" = "downloaded" ] ||
        bad "leg 4: download of the corrupted bundle did not complete (got: $(printf '%s' "$out" | cut -c1-200))"
    out=$(_os_step '{"action":"verify"}' 120)
    st=$(printf '%s' "$out" | jq -r '.status')
    if [ "$st" = "rejected" ] && printf '%s' "$out" | jq -r '.error' | grep -q "signature"; then
        ok "leg 4: BAD SIGNATURE REFUSED — verify rejects the corrupted bundle with the honest error"
    else
        bad "leg 4: verify of the corrupted bundle did not refuse on signature (got: $(printf '%s' "$out" | cut -c1-200))"
    fi
    if ! _ssh "test -f /data/pithead/data/os-update/pithead-os-$tag.raucb"; then
        ok "leg 4: the mis-signed bundle was deleted"
    else
        bad "leg 4: the mis-signed bundle is still staged"
    fi

    # Resume: restore the good bundle, pre-stage a genuine prefix as the interrupted transfer,
    # and require the download to CONTINUE from it rather than start over.
    #
    # `resumed_from` alone is tautological (#1051): it is the size of the .partial file THIS
    # test staged, echoed back before curl ever runs, so it holds whether or not curl actually
    # resumed — a client that silently restarted from zero would still report it. The independent
    # witness is what the SERVER actually received on the wire (`.requests.log`, written by
    # `_serve_update_dir` above): a genuine resume sends `Range: bytes=4194304-`; a silent restart
    # sends no Range header (or one starting at 0). Truncate the log first so a stale request from
    # an earlier step in this leg can't be misread as this one's.
    : >"$srv/.requests.log"
    cp "$srv/good.raucb" "$srv/pithead-os-$tag.raucb"
    head -c 4194304 "$srv/good.raucb" |
        _ssh "mkdir -p /data/pithead/data/os-update && cat > /data/pithead/data/os-update/pithead-os-$tag.raucb.partial" || {
        bad "leg 4: could not pre-stage the interrupted download"
    }
    out=$(_os_step "{\"action\":\"download\",\"version\":\"$tag\"}" 900)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "downloaded" ] &&
        [ "$(printf '%s' "$out" | jq -r '.resumed_from // 0')" = "4194304" ] &&
        grep -q "^pithead-os-$tag.raucb bytes=4194304-\$" "$srv/.requests.log" 2>/dev/null; then
        ok "leg 4: RESUME PROVEN — the download continued from the interrupted 4 MiB, not from zero (server witnessed the Range request)"
    else
        bad "leg 4: the download did not resume from the staged prefix (got: $(printf '%s' "$out" | cut -c1-200); server saw: $(cat "$srv/.requests.log" 2>/dev/null | tr '\n' ';'))"
    fi

    # Verify + install: the good bundle passes for real, the install writes the spare slot while
    # the stack keeps running, and the in-flight flag arms the post-reboot verdict.
    out=$(_os_step '{"action":"verify"}' 180)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "verified" ]; then
        ok "leg 4: the good bundle verifies (signature + compatible + version)"
    else
        bad "leg 4: the good bundle failed verify (got: $(printf '%s' "$out" | cut -c1-200))"
        _leg4_srv_stop
        return
    fi
    out=$(_os_step '{"action":"install"}' 900)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "installed" ]; then
        ok "leg 4: install wrote the spare slot through the dashboard action"
    else
        bad "leg 4: install did not complete (got: $(printf '%s' "$out" | cut -c1-200))"
        # The runner deletes .install.log on a failed install and the result carries only a whitelisted last line
        # (#1651: one gate red said "[ERROR] rauc install failed", guest gone) — keep the guest's own account.
        SSH_TIMEOUT=120 _ssh "{ echo '== pithead-control.service (the root runner)'; journalctl -b -u pithead-control.service -o short-iso --no-pager -n 200; echo '== journal rauc/os-install lines'; journalctl -b -o short-iso --no-pager | grep -aiE 'rauc|os.install|os-update' | tail -300; echo '== rauc status'; rauc status; echo '== df'; df -h /data /tmp; echo '== free'; free -m; echo '== oom'; dmesg | grep -aiE 'oom|killed process'; } 2>&1" >"$SERIAL.leg4-install" || true
        [ -s "$SERIAL.leg4-install" ] && info "install diagnostics kept at $SERIAL.leg4-install" || info "install diagnostics capture came back EMPTY (guest unreachable, or the 120 s cap hit) — read $SERIAL.failed"
        _leg4_srv_stop
        return
    fi
    if [ "$(_ssh "jq -r '.to' /data/pithead/data/os-update/in-flight.json" 2>/dev/null)" = "${tag#v}" ]; then
        ok "leg 4: the in-flight flag names the target version"
    else
        bad "leg 4: no in-flight flag after the install — the post-reboot verdict is unarmed"
    fi
    if [ "$(_ssh "jq -r '.step' /data/pithead/data/control/results/os-update-state.json" 2>/dev/null)" = "reboot-pending" ]; then
        ok "leg 4: the persisted state says reboot-pending (survives reloads)"
    else
        bad "leg 4: the persisted state does not say reboot-pending"
    fi

    # The explicit reboot intent — nothing rebooted on its own up to here.
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v1" ] && ok "leg 4: nothing auto-rebooted — still on v1 until the operator says so" ||
        bad "leg 4: expected to still be on v1 before the reboot intent, got '$marker'"
    before=$(_boot_id) || info "could not read the boot id before the reboot intent — a reconnect and a reboot would look alike"
    [ -n "$before" ] && _os_step '{"action":"reboot"}' 30 >/dev/null 2>&1 || true # the machine goes away mid-poll; no id, no reboot
    [ -n "$before" ] && _wait_new_boot "$before" 420 || {
        bad "leg 4: guest never returned after the dashboard reboot intent"
        _leg4_srv_stop
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "leg 4: the dashboard-driven update booted v2" ||
        bad "leg 4: expected v2 after the dashboard reboot, got '$marker'"
    # The verdict is written only when pithead-boot's health gate commits the slot — waiting for
    # it proves install + reboot + commit landed, and that the banner's data exists.
    local vdeadline=$(($(date +%s) + 900)) verdict=""
    while [ "$(date +%s)" -lt "$vdeadline" ]; do
        verdict=$(_ssh "jq -r '.verdict.outcome // \"\"' /data/pithead/data/control/results/os-update-state.json" 2>/dev/null)
        [ -n "$verdict" ] && break
        sleep 15
    done
    if [ "$verdict" = "updated" ]; then
        ok "leg 4: COMMIT + VERDICT — the slot committed and the verdict says updated"
    else
        bad "leg 4: no 'updated' verdict after the reboot (got '${verdict:-none}') — commit or verdict is broken"
    fi
    if curl -sSk -u "$DASH_USER:$DASH_PASS" "https://$ip/api/state" 2>/dev/null |
        jq -e '.os_update.verdict.outcome == "updated"' >/dev/null 2>&1; then
        ok "leg 4: the success banner's verdict reaches /api/state"
    else
        bad "leg 4: /api/state does not carry the updated verdict — the banner would never show"
    fi
    _leg4_srv_stop
}
