# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_rig_mining_up() { # <tries>, 10 s apart — 0 once the xmrig unit is active with its process up
    local n=0
    while [ "$n" -lt "$1" ]; do
        _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null" && return 0
        sleep 10
        n=$((n + 1))
    done
    return 1
}

phase_rig() {
    info "phase: rig (the OTHER machine this image installs — mines instead of coordinating)"
    # One image, two machines. Every other phase proves the coordinator; this one proves that
    # answering "RigForge" produces a box with no stack at all, mining the baked binary without
    # compiling or reaching the network, that takes an A/B update exactly like a coordinator. A
    # rig has no dashboard to complain through, so one that never starts is invisible otherwise.
    local img token jar body scode marker card card_tok rtok pcode ptries=0

    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 240 || {
        bad "guest never answered SSH (ip: ${ip:-none})"
        return
    }
    ok "image boots ($ip)"

    local tries=0
    token=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token ever appeared on the console"
        return
    }
    _wait_setup_page 120 || {
        bad "wizard gate never served"
        return
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "token was not accepted"
        rm -f "$jar"
        return
    }
    grep -q "wizard_session" "$jar" || {
        bad "auth returned no session cookie — the submit below would be unauthenticated"
        rm -f "$jar"
        return
    }

    # The pool: the guest's OWN sshd — a KVM guest has no Pithead on its LAN, and the host-side gate only
    # dials a TCP listener before committing. It deliberately does NOT prove an accepted share (the same
    # limit the coordinator's local-miner leg documents). XMRig dials it, gets no stratum and retries
    # forever, which is the point: the miner must come up and STAY up on a pool that does not answer.
    body="role=rig&rig_pool=127.0.0.1:22&rig_worker=kvm-rig"
    scode=$(curl -sSk -b "$jar" --data "$body" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "rig submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return
    }
    ok "rig role submitted through the wizard"
    tries=0
    while [ "$tries" -lt 24 ]; do
        card=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        case "$card" in *'"worker"'*) break ;; esac
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no rig card appeared on the page"
        rm -f "$jar"
        return
    }
    case "$card" in
    *'"password"'*) bad "the rig card published a dashboard password — a rig serves no dashboard" ;;
    *) ok "the rig card is worker + pool, with no login (a rig has none)" ;;
    esac
    card_tok=$(printf '%s' "$card" | jq -r '.token // ""' 2>/dev/null)
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null || true
    rm -f "$jar"

    # ---- the machine that came out: a rig, not a small coordinator ------------------------
    if _rig_mining_up 36; then
        ok "the rig mines (xmrig unit active, process running) with no reboot in between"
    else
        bad "the rig never started mining (unit: $(_ssh 'systemctl is-active xmrig' 2>/dev/null || echo unknown))"
        info "  firstboot journal tail: $(_ssh "journalctl -u pithead-firstboot -n 8 --no-pager -o cat" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
    fi
    [ "$(_ssh 'cat /data/pithead/machine-role' | tr -d '\r\n')" = "rig" ] &&
        ok "the role marker says rig" || bad "the role marker is not rig"
    [ -z "$(_ssh 'ls /data/pithead/config.json 2>/dev/null')" ] &&
        ok "no coordinator config was ever written (a rig has none)" ||
        bad "a config.json appeared on a rig — the coordinator contract leaked into the rig role"
    if _ssh "jq -e '.pools[0].url == \"127.0.0.1:22\" and .pools[0].user == \"kvm-rig\"' /data/rigforge/config.json >/dev/null"; then
        ok "the miner's config is derived from rig.json (pool + worker name)"
    else
        bad "the rig's miner config does not match its answers ($(_ssh "jq -c '.pools' /data/rigforge/config.json 2>/dev/null" | cut -c1-100))"
    fi
    # #1836: the rig's token guards every API, the sister feed the coordinator probes exists, and the
    # writable control path is pinned to the pool host — 127.0.0.1 here, so the guest probes itself over
    # loopback and this host, an unpinned source, is dropped (loopback answering proves the port is alive).
    rtok=$(_ssh "jq -r '.ACCESS_TOKEN // \"\"' /data/rigforge/config.json" | tr -d '\r')
    [[ "$rtok" =~ ^[0-9a-f]{32}$ ]] && ok "the miner's config carries a minted 32-hex control token" || bad "no control token in the rig's config (got '${rtok:0:8}')"
    [ -n "$card_tok" ] && [ "$card_tok" = "$rtok" ] && ok "the rig card showed the SAME token the miner enforces" || bad "the card's token ('${card_tok:0:8}') is not the miner's ('${rtok:0:8}')"
    _ssh "jq -e '.api == \"enabled\" and .control == \"enabled\" and .api_allow_from == \"127.0.0.1\" and (has(\"control_upgrade\") | not)' /data/rigforge/config.json >/dev/null" &&
        ok "sister API + control enabled, pinned to the pool host; control_upgrade untouched" ||
        bad "the rig's API keys are not what #1836 renders: $(_ssh "jq -c 'del(.pools, .ACCESS_TOKEN)' /data/rigforge/config.json" | cut -c1-120)"
    _rig_http() { _ssh "curl -s -m 5 -o /dev/null -w '%{http_code}' $*" 2>/dev/null | tr -d '\r'; }
    while [ "$ptries" -lt 12 ] && [ "$(_rig_http -H "'Authorization: Bearer $rtok'" http://127.0.0.1:8081/1/summary)" != "200" ]; do
        sleep 5
        ptries=$((ptries + 1))
    done
    [ "$ptries" -lt 12 ] && ok "the sister feed answers 200 with the token" || bad "the sister feed never answered 200 with the token"
    pcode=$(_rig_http http://127.0.0.1:8081/1/summary)
    [ "$pcode" = "401" ] && ok "the sister feed refuses without the token (401)" || bad "the sister feed answered '${pcode}' without a token"
    pcode=$(_rig_http http://127.0.0.1:8080/1/summary)
    case "$pcode" in 401 | 403) ok "XMRig's own API is closed without the token ($pcode)" ;; *) bad "XMRig's API on 8080 answered '${pcode}' with no token — still open on the LAN" ;; esac
    pcode=$(_rig_http http://127.0.0.1:8082/)
    [ -n "$pcode" ] && [ "$pcode" != "000" ] && ok "the control port listens (loopback answers $pcode)" || bad "the control port does not answer even on loopback ('${pcode}')"
    pcode=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ip:8082/" 2>/dev/null)
    [ "${pcode:-000}" = "000" ] && ok "the control port is unreachable from an unpinned source (this host)" || bad "the control port answered '$pcode' from an unpinned source"
    # THE assertion of this phase: no stack. Not a stopped stack, not a held one — none started.
    local names
    names=$(_ssh "podman ps -a --format '{{.Names}}'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    if [ -z "${names// /}" ]; then
        ok "no compose stack was started — no containers exist at all on a rig"
    else
        bad "a rig started containers: '$names'"
    fi
    # Prebuilt-first, proven by identity: a recompile gives a DIFFERENT binary; a clone has no path to github.
    if _ssh "cmp -s /data/rigforge/data/worker/xmrig/build/xmrig /opt/rigforge/prebuilt/xmrig/build/xmrig"; then
        ok "the rig mines the BAKED binary byte for byte — no compile, no clone, no clearnet"
    else
        bad "the running miner is not the baked prebuilt — something compiled or fetched on first boot"
    fi
    # Removable-root tolerance: an in-memory journal, so a stick root takes no rotating writes (the role's setting, not the medium's).
    [ "$(_ssh 'systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -c "^Storage=volatile"')" != "0" ] &&
        ok "journald is volatile on a rig (a rig's root may be the stick it mines from)" ||
        bad "journald is still persistent on a rig — a USB root would take rotating writes"

    # ---- reboot: pithead-boot owns a rig now, and commits its slot -------------------------
    info "reboot leg — the rig must come back mining, and commit its own slot"
    _reboot_wait reboot 300 || {
        bad "the rig never returned from the reboot"
        return
    }
    _rig_mining_up 24 &&
        ok "the rig returned mining with no hands on it (its unit lives in /run and died with the reboot)" ||
        bad "the rig did not return after the reboot — its runtime unit was never re-rendered"
    # WHICH unit owns the boot is the whole R4 fork: the wizard's window is closed, pithead-boot runs.
    [ "$(_ssh 'systemctl is-active pithead-boot' | tr -d '\r\n')" = "active" ] &&
        ok "pithead-boot owns a provisioned rig's boot" ||
        bad "pithead-boot did not run on the rig (its condition still excludes a machine with no config.json)"
    _ssh "systemctl is-active --quiet pithead-firstboot" &&
        bad "the first-boot wizard ran again on a provisioned rig" ||
        ok "the wizard window is closed on a provisioned rig (no setup page on every boot)"
    local failed_units
    failed_units=$(_ssh "systemctl --failed --no-legend --no-pager --plain" 2>/dev/null |
        awk '$1 !~ /^[0-9a-f]{64}-[0-9a-f]+\.service$/' | tr -s ' ' | tr '\n' ';')
    [ -z "${failed_units//[; ]/}" ] && ok "no failed systemd units on the rig after the reboot" ||
        bad "failed units on the rig after the reboot: $failed_units"
    # The commit gate, rig-shaped: a rig that cannot commit rolls back every update; the pool answers nothing, and must not matter.
    local genv tries3=0
    while [ "$tries3" -lt 18 ]; do
        genv=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv" in *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*) break ;; esac
        sleep 10
        tries3=$((tries3 + 1))
    done
    case "$genv" in
    *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*)
        ok "the rig committed its own slot on the miner running (A_OK=1 A_TRY=0), pool unanswered"
        ;;
    *) bad "the rig never self-committed — grubenv: ${genv:-unreadable}" ;;
    esac
    rig_setup_again_legs "$card_tok" "$token" # #1318: Keep it, then Set up again as the same rig (tests/os/setup-again-leg.sh)

    # ---- A/B update: identical pipeline, identical outcome --------------------------------
    info "update leg — a rig takes a bundle exactly like a coordinator"
    local bundle
    bundle=$(_build_bundle v2) || {
        bundle_build_evidence
        bad "v2 bundle build failed — read the build output above (/tmp/os-fault-bundle.log)"
        return
    }
    _stage_bundle "$bundle" || {
        bad "staging the bundle on the rig failed"
        return
    }
    _ssh "$(_install_cmd /data/update.bundle)" || {
        bad "the v2 install failed on the rig"
        return
    }
    ok "v2 installed into the rig's spare slot"
    _reboot_wait "$(_boot_spare_cmd)" 300 || {
        bad "the rig never returned after booting the spare slot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker | tr -d '\r\n')
    [ "$marker" = "v2" ] && ok "the rig's spare slot booted with v2" || {
        bad "expected v2 in the rig's spare slot, got '$marker'"
        return
    }
    # The state that must survive a whole-slot replacement: the role and its answers live on
    # /data, so the new slot has to come up as the SAME rig.
    [ "$(_ssh 'cat /data/pithead/machine-role' | tr -d '\r\n')" = "rig" ] &&
        ok "the role survived the slot swap (it lives on /data, not in the image)" ||
        bad "the updated slot lost the rig role"
    _rig_mining_up 24 && ok "the rig mines again on the updated slot" ||
        bad "the rig stopped mining after the A/B update"
    # No harness mark-good: the boot that just brought the miner up must have COMMITTED — a rig commits on the
    # miner running, the same event this leg just waited for. That coupling is also why an "uncommitted
    # revert" is not observable here: on a provisioned rig the commit window closes the moment the miner is up
    # (seconds), which is the property itself, not a gap. The generic uncommitted-fallback machinery — same
    # grub.cfg, same RAUC — is proven by the update phase on an unprovisioned box, where no boot path
    # self-commits. This leg's first run asserted the revert anyway and refuted ITSELF: the rig had already
    # committed, the reboot stayed v2, and a follow-up install then targeted the wrong slot.
    local genv2 tries4=0
    while [ "$tries4" -lt 24 ]; do
        genv2=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv2" in *B_OK=1*B_TRY=0* | *B_TRY=0*B_OK=1*) break ;; esac
        sleep 10
        tries4=$((tries4 + 1))
    done
    case "$genv2" in
    *B_OK=1*B_TRY=0* | *B_TRY=0*B_OK=1*)
        ok "the rig self-committed the UPDATED slot (B_OK=1 B_TRY=0) — no harness hands"
        ;;
    *) bad "the rig never self-committed the updated slot — grubenv: ${genv2:-unreadable}" ;;
    esac
    _reboot_wait reboot 300 || {
        bad "the rig never returned after the post-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker | tr -d '\r\n')
    [ "$marker" = "v2" ] && ok "COMMIT: the update persists on the rig across reboot" ||
        bad "expected v2 on the rig after commit, got '$marker'"
    rig_setup_again_coordinator_leg "$token" # #1318: Set up again as a coordinator, from the updated slot
}
