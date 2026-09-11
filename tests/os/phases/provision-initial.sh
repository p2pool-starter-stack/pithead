# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# The provision leg proper, plus the one assertion that must survive its aborts.
#
# #2059: the Tor-only egress ENFORCEMENT backstop used to be the last ~55 lines of the body below,
# downstream of a dozen `return 1` aborts on unrelated liveness legs. Every battery to date aborted
# upstream of it, so the repo's only proof that the kernel enforces Tor-only egress never ran —
# silently, while the battery reported on everything it did reach, and a fail-open appliance shipped
# green. It now runs on EVERY path and says out loud when it could not be exercised. The body's rc
# is preserved, so an abort still stops the reboot and migration legs exactly as before.
_phase_provision_initial() {
    local rc=0
    _phase_provision_initial_body || rc=$?
    phase_provision_egress_backstop "$rc"
    return "$rc"
}

_phase_provision_initial_body() {
    info "phase: provision (wizard HTTP submit -> setup -> stack containers up)"

    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return 1
    }
    _vm_boot_disk "$img" && _wait_ssh 240 || {
        bad "guest never answered SSH (ip: ${ip:-none})"
        return 1
    }
    ok "image boots ($ip)"

    # The wizard's one-time token, exactly where a human gets it: the console.
    tries=0
    token=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token ever appeared on the console"
        return 1
    }
    ok "one-time token read from the console ($token)"
    _wait_setup_page 120 || {
        bad "wizard gate never served"
        return 1
    }

    jar=$(mktemp)
    # https, and PROVE the cookie landed: auth against :80 once hit the TLS redirect, whose 301
    # carries no cookie — curl -f called that success, the jar stayed empty, and the unauthenticated
    # submit's redirect ALSO read as success. Status codes and the jar are asserted, not inferred.
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "token was not accepted"
        rm -f "$jar"
        return 1
    }
    grep -q "wizard_session" "$jar" || {
        bad "auth returned no session cookie — the submit below would be silently unauthenticated"
        rm -f "$jar"
        return 1
    }
    provision_node_preflight_retention "$ip" "$jar" || {
        rm -f "$jar"
        return 1
    }
    provision_setup_failure_recovery "$ip" "$jar" "$token" || {
        rm -f "$jar"
        return 1
    }
    scode=$(provision_browser_submit "$ip" "$jar")
    [ "$scode" = "200" ] || {
        bad "config submit did not return 200 (got ${scode:-none} — a 30x means the session was not accepted)"
        rm -f "$jar"
        return 1
    }
    # The jar lives on: the handoff below is authenticated too (deleting it here once made the poll silently unauthenticated).
    ok "config submitted through the wizard"
    # The credentials handoff: the host publishes the generated login and HOLDS provisioning until
    # it is acknowledged (the page goes dark after). The login is kept for the OS-update check below.
    local handoff_body="" page_err=""
    tries=0
    while [ "$tries" -lt 24 ]; do
        handoff_body=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        if printf '%s' "$handoff_body" | grep -q '"password"'; then
            ok "generated credentials published to the page"
            break
        fi
        page_err=$(provision_page_error "$ip" "$jar")
        [ -z "$page_err" ] || break # the host refused: say what it said, not that it timed out
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] && [ -z "$page_err" ] || {
        bad "no credentials handoff appeared on the page${page_err:+ — the page says: $page_err}"
        rm -f "$jar"
        return 1
    }
    if printf '%s' "$handoff_body" | jq -r '.password // ""' | grep -qE '^[A-Za-z0-9]{32}$'; then
        ok "the card carries a generated 32-character password (auth_mode=auto, #1846)"
    else
        bad "the card's password is not a generated one: $(printf '%s' "$handoff_body" | jq -c '.password // null')"
    fi
    scode=$(curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "handoff acknowledgement did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return 1
    }
    ok "handoff acknowledged — provisioning released"
    rm -f "$jar"
    if curl -sS -o /dev/null -w '%{http_code}' -m 5 "http://$ip/" 2>/dev/null | grep -q '^30'; then
        ok "plain :80 redirects to TLS rather than refusing"
    else
        bad "plain :80 does not redirect — an operator typing a bare address sees a dead port"
    fi

    # The host validates, installs config.json, and runs setup — which pulls the release images
    # (cosign-verified) and starts the stack. Pulls are the slow part; be generous.
    if ! _ssh "for i in \$(seq 120); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        bad "the submitted config never became /data/pithead/config.json (validation output: $(_ssh "cat /data/pithead/data/firstboot/error.txt 2>/dev/null" | cut -c1-120))"
        return 1
    fi
    ok "config validated and installed by the host"

    local deadline=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in
        *dashboard*caddy* | *caddy*dashboard*) break ;;
        esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "stack containers are running (podman: $names)"
        ;;
    *)
        bad "stack never came up within 25m — running: '${names:-none}'"
        stack_never_up_evidence # #2043: the guest is recycled next, so ask it now
        info "  setup journal tail: $(_ssh "journalctl -u pithead-firstboot -n 5 --no-pager -o cat" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
        return 1
        ;;
    esac
    # Caddy fronts the dashboard once the wizard's window closes; self-signed on :443 by default.
    # Status-based on purpose: the landing response may be a redirect to the login page or an
    # auth challenge, both empty-bodied — any well-formed HTTP answer proves caddy is proxying.
    # The window covers the dashboard's healthcheck start period, not just its process start.
    tries=0
    local served=0
    code=000
    while [ "$tries" -lt 60 ]; do
        # `|| true`, never `|| echo 000`: on a connection failure curl ALREADY prints 000 (-w
        # always fires) and exits non-zero, so the echo appended a SECOND 000 — the retry case
        # below then matched neither, broke on the first iteration, and reported the impossible
        # "HTTP 000000". The loop existed to wait out exactly that state and never once waited.
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
        case "$code" in
        2?? | 3?? | 401 | 403)
            ok "dashboard is served through caddy (HTTP $code)"
            served=1
            break
            ;;
        esac
        sleep 5
        tries=$((tries + 1))
    done
    if [ "$served" -ne 1 ]; then
        bad "no HTTP answer behind caddy on :443 within 5m (last: $code)"
        return 1
    fi

    pv_user=$(printf '%s' "$handoff_body" | jq -r '.username // "admin"' 2>/dev/null)
    pv_pass=$(printf '%s' "$handoff_body" | jq -r '.password // ""' 2>/dev/null)
    if [ -n "$pv_pass" ] && curl -sSk -u "$pv_user:$pv_pass" "https://$ip/api/state" 2>/dev/null |
        jq -e '.os_update.step' >/dev/null 2>&1; then
        ok "appliance state carries os_update — the dashboard OS-update control renders"
    else
        bad "no os_update in /api/state — the appliance has no reachable OS-update control"
    fi
    phase_provision_control_regressions "$pv_user" "$pv_pass"
    phase_provision_hostname_regressions "$pv_user" "$pv_pass"
    phase_provision_sensitive_regressions "$pv_user" "$pv_pass" || bad "sensitive appliance regression phase aborted before completing required checks"
    # ---- local-miner leg (#796): enable -> xmrig up -> wired to the machine's own stratum ---
    # The submit above asked to mine on the box itself, so the built-in RigForge worker must
    # come up without any hands: setup renders its config, runs its appliance-mode setup, and
    # the miner dials the machine's own stratum.
    #
    # The leg used to demand an accepted share, and that end of the chain cannot exist here: on a
    # fresh machine the product itself HOLDS p2pool and xmrig-proxy until the local chains sync
    # (#35 — the dashboard logs the hold and stops both), and a KVM guest syncing Monero over Tor
    # onto a 40 GiB scratch disk never clears that gate. No budget fixes a state the product
    # enforces on purpose. The share assertion lives where a synced node exists — the release e2e
    # on the bench. What the harness CAN prove, it now does, link by link: the miner runs, the hold
    # is the deliberate one (p2pool stopped CLEAN — a crash-looping p2pool, the #829 failure this
    # leg first caught, dies non-zero under the same gate), and the rendered worker config points
    # at this machine's own stratum.
    local mtries=0 miner_up=0
    while [ "$mtries" -lt 36 ]; do
        if _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null"; then
            miner_up=1
            break
        fi
        sleep 10
        mtries=$((mtries + 1))
    done
    if [ "$miner_up" -eq 1 ]; then
        ok "built-in miner is up (xmrig unit active, process running)"
    else
        bad "the built-in miner never came up (unit: $(_ssh 'systemctl is-active xmrig' 2>/dev/null || echo unknown))"
        info "  local-miner journal tail: $(_ssh "journalctl -u pithead-firstboot -n 5 --no-pager -o cat" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
    fi
    # #1724: the pool has a SECOND writer — xmrig runs as root and grows nr_hugepages through sysfs
    # before a large-page allocation, so the declared ceiling bounds the sizer alone. verify-image
    # pins the drop-in that SHIPPED; this reads what systemd LOADED, the pool, and the 1 GiB pool the
    # sizer never writes. Verdict + the ARMING caveat on it: tests/os/hugepages-boot-verdict.sh.
    if [ "$miner_up" -eq 1 ]; then
        local mhp mro m1g mv
        mhp=$(_ssh "awk '/^HugePages_Total/{print \$2}' /proc/meminfo" | tr -d '\r\n') || mhp=""
        mro=$(_ssh "systemctl show xmrig -p ReadOnlyPaths --value" | tr -d '\r\n') || mro=""
        m1g=$(_ssh "cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages" | tr -d '\r\n') || m1g=""
        if mv=$(hugepages_miner_verdict "$mhp" "$mro" "$m1g"); then ok "$mv"; else bad "$mv"; fi
    fi
    # The deliberate pre-sync state: the dashboard's sync gate (#35) holds mining until the
    # chains catch up, and says so. Its absence would mean mining died some OTHER way.
    local gtries=0 gate_seen=0
    while [ "$gtries" -lt 30 ]; do
        if _ssh "podman logs dashboard 2>&1 | grep -q 'holding p2pool, xmrig-proxy until synced'"; then
            gate_seen=1
            break
        fi
        sleep 10
        gtries=$((gtries + 1))
    done
    if [ "$gate_seen" -eq 1 ]; then
        ok "fresh chains hold mining behind the sync gate — the deliberate pre-sync state (#35)"
    else
        bad "no sync-gate hold in the dashboard log — mining is down for some other reason"
    fi
    # Held, not crashed: the gate stops a healthy p2pool cleanly (exit 0), unlike #829's crash.
    local pstate p2pool_log
    pstate=$(_ssh "podman inspect p2pool --format '{{.State.Running}} {{.State.ExitCode}}'" | tr -d '\r')
    case "$pstate" in
    "true 0" | "false 0")
        ok "p2pool stopped clean under the gate, not by a crash ($pstate)"
        ;;
    *)
        bad "p2pool did not survive its own start — crashed rather than held (state: ${pstate:-unreadable})"
        info "  p2pool log tail: $(_ssh "podman logs --tail 3 p2pool 2>&1" | tr '\n' ' ' | cut -c1-200)"
        ;;
    esac
    if ! p2pool_log=$(_ssh "podman logs p2pool 2>&1"); then bad "p2pool container logs are unreadable"; elif awk '{ gsub(/\033\[[0-9;]*m/, "") } /P2Pool v[0-9]/ { found=1 } END { exit !found }' <<<"$p2pool_log"; then ok "p2pool daemon output remains observable through bounded container logs (#1989)"; else bad "p2pool daemon startup is absent from container logs"; fi
    if _ssh "test ! -e /data/pithead/data/p2pool/p2pool.log"; then ok "p2pool creates no persistent file log (#1989)"; else bad "p2pool created persistent data/p2pool/p2pool.log"; fi
    # The wiring itself (#796): the worker's rendered config dials THIS machine's stratum.
    if _ssh "jq -e '.pools[0].url == \"127.0.0.1:3333\"' /data/rigforge/config.json >/dev/null"; then
        ok "built-in miner is wired to the machine's own stratum (127.0.0.1:3333)"
    else
        bad "the built-in miner's config does not dial the machine's own stratum (pools: $(_ssh "jq -c '.pools' /data/rigforge/config.json 2>/dev/null" | cut -c1-100))"
    fi

}
