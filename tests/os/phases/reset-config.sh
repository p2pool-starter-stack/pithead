# shellcheck shell=bash
# shellcheck disable=SC2154  # ip, jar, token, tries, scode, names, deadline and SERIAL are run.sh's/phase_reset's
: "${OS_RUN_SUITE:?source via the suite runner}"
# leg 0 of phase_reset (#2347): config-reset's whole promise — chains and the onion address kept,
# the wizard re-armed, reconfiguring costs no resync — is a claim about systemd conditions and
# disk state that only a real boot can settle. Runs on the SAME provisioned guest phase_reset's
# factory-reset leg is about to wipe, before it wipes it. A sibling, not more lines in reset.sh,
# which would otherwise cross its docs/dev/file-budget.tsv ceiling (#1430's rule, applied here
# first) — $ip, $jar, $token, $tries, $scode, $names, $deadline and $SERIAL are phase_reset's own
# locals, read and written here through Bash's dynamic function scope, the same trick
# phases/provision-initial.sh uses.
_phase_reset_config() {
    info "leg 0 — config-reset must keep chains and the onion address, clear the config, and re-arm the wizard"
    local onion_before onion_after cr_height_before cr_height_after cr_height_deadline fb_ran boot_ran
    local cr_want cr_probe cr_what
    onion_before=$(_ssh "podman exec tor cat /var/lib/tor/monero/hostname" 2>/dev/null | tr -d '\r')
    # monerod's RPC can still be starting even once "stack containers running" above only checked
    # dashboard+caddy — its baked archive is the largest and loads last (appliance-egress-leg.sh's
    # own comment on the same wait). Poll the full 5 minutes that leg gives monerod, not
    # provision-power-cut.sh's tighter 18x10s, which runs only after the rest of the provision
    # phase has already given monerod plenty of time to start.
    cr_height_deadline=$(($(date +%s) + 300))
    while [ "$(date +%s)" -lt "$cr_height_deadline" ]; do
        cr_height_before=$(_monerod_height)
        [ -n "$cr_height_before" ] && break
        sleep 5
    done
    if [ -n "$onion_before" ] && [ -n "$cr_height_before" ]; then
        ok "config-reset baseline: onion $onion_before, monerod height $cr_height_before"
    else
        bad "could not capture a config-reset baseline (onion: ${onion_before:-none}, height: ${cr_height_before:-none})"
        return 1
    fi

    if _reboot_wait "cd /data/pithead && ./pithead config-reset -y" 300; then
        ok "guest returned after the config-reset reboot"
    else
        bad "guest never returned after config-reset — BRICKED"
        return 1
    fi

    # Two systemd conditions in opposition, neither observable from a stub: firstboot's
    # ConditionPathExists is `!config.json`/`!machine-role`, boot's is the same paths without the
    # `!`, so exactly one may have run this boot. `is-active` alone cannot tell a correctly-skipped
    # unit from one that already finished (RemainAfterExit=no) — provisioning-settled.sh's
    # ConditionResult probe can (#2055 G3).
    fb_ran=no boot_ran=no
    unit_ran_this_boot pithead-firstboot && fb_ran=yes
    unit_ran_this_boot pithead-boot && boot_ran=yes
    if [ "$fb_ran" = yes ] && [ "$boot_ran" = no ]; then
        ok "the wizard is re-armed and pithead-boot stands down — the two conditions came out opposite, as designed"
    else
        bad "config-reset did not flip the boot conditions (firstboot ran: $fb_ran, boot ran: $boot_ran)"
    fi

    # What config-reset must clear, and the one thing it must keep, as a table: one row per probe
    # instead of one five-line copy per probe. machine-role is a row of its own rather than only
    # the boot-condition check above, which proves the EFFECT — this proves the mechanism that
    # produced it, so a future re-arm done some other way is still legible here (#2347).
    #
    # `</dev/null` on the probe is load-bearing, not tidiness: `_ssh` runs ssh without -n, and ssh
    # reads stdin, which inside this loop is the here-doc — the first probe would swallow every
    # remaining row and the loop would end after one line (measured on the 2026-09-11 battery;
    # appliance-egress-leg.sh carries the same note for the same reason). A here-doc and never a
    # pipe, too: `ok`/`bad` increment the run's counters, which a piped subshell would discard.
    while IFS='|' read -r cr_want cr_probe cr_what; do
        if _ssh "$cr_probe" </dev/null >/dev/null 2>&1; then
            if [ "$cr_want" = kept ]; then
                ok "$cr_what survived config-reset"
            else
                bad "$cr_what survived config-reset"
            fi
        elif [ "$cr_want" = kept ]; then
            bad "$cr_what is gone — config-reset removed something it promised to keep"
        else
            ok "$cr_what is gone"
        fi
    done <<'CR_PROBES'
gone|test -f /data/pithead/config.json|config.json
gone|test -f /data/pithead/.env|.env
gone|test -f /data/pithead/Caddyfile|Caddyfile
gone|test -f /data/pithead/machine-role|the machine-role marker that held the wizard shut
gone|nft list table inet pithead_egress|the Tor-only egress table
kept|test -d /data/pithead/data/monero|the monero chain directory
CR_PROBES

    if _wait_setup_page 120; then
        ok "the wizard gate serves again after config-reset"
    else
        bad "no wizard gate after config-reset — the machine did not return to first-boot"
        return 1
    fi

    # Re-provision through the same browser-shaped submit phase_provision uses (#1846), the path
    # an operator actually takes.
    tries=0
    token=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token appeared on the console after config-reset"
        return 1
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "the post-config-reset token was not accepted"
        rm -f "$jar"
        return 1
    }
    scode=$(provision_browser_submit "$ip" "$jar")
    [ "$scode" = "200" ] || {
        bad "post-config-reset config submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return 1
    }
    tries=0
    while [ "$tries" -lt 24 ]; do
        curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"' && break
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no credentials handoff appeared after re-provisioning through config-reset"
        rm -f "$jar"
        return 1
    }
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    ok "reconfigured through the wizard after config-reset"

    if ! _ssh "for i in \$(seq 120); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        bad "the resubmitted config never became /data/pithead/config.json"
        return 1
    fi

    names="" deadline=$(($(date +%s) + 1500))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in
        *dashboard*caddy* | *caddy*dashboard*) break ;;
        esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "stack containers are running again after config-reset ($names)"
        ;;
    *)
        bad "stack never came back up after config-reset — running: '${names:-none}'"
        stack_never_up_evidence
        return 1
        ;;
    esac

    # The claims that only a real boot can settle (#2347): the onion address is the SAME one —
    # read from TOR_DATA_DIR's hostname files, not .env (#2379) — and the chain resumed rather
    # than resynced. Neither `bad` below returns: these are terminal verdicts, like leg 1's own
    # machine-id/host-key checks below in this same file, not guest-availability gates — the
    # battery's exit code comes from the global PASS/FAIL tally `ok`/`bad` update
    # (tests/os/lib/core.sh), not from this function's return value, so a red here still fails
    # the run without needing to skip whatever leg runs next.
    onion_after=$(_ssh "podman exec tor cat /var/lib/tor/monero/hostname" 2>/dev/null | tr -d '\r')
    if [ -n "$onion_after" ] && [ "$onion_after" = "$onion_before" ]; then
        ok "the onion address survived config-reset unchanged ($onion_after)"
    else
        bad "the onion address did not survive config-reset (before: $onion_before, after: ${onion_after:-none})"
    fi
    # The same 300 s ceiling the baseline read above gets, and for the same reason: monerod is
    # the largest image and the last container to answer, so a tighter bound reports "after:
    # unreadable" for a node that was merely still starting. The structurally identical M10.3
    # read in provision-power-cut.sh did exactly that on jobs 713 and 715.
    cr_height_deadline=$(($(date +%s) + 300))
    while [ "$(date +%s)" -lt "$cr_height_deadline" ]; do
        cr_height_after=$(_monerod_height)
        [ -n "$cr_height_after" ] && break
        sleep 5
    done
    if [ -n "$cr_height_after" ] && [ "$cr_height_after" -ge "$cr_height_before" ]; then
        ok "monerod resumed at or past its pre-reset height after config-reset ($cr_height_before -> $cr_height_after) — no resync"
    else
        bad "monerod height regressed or is unreadable after config-reset (before: $cr_height_before, after: ${cr_height_after:-none})"
    fi
}
