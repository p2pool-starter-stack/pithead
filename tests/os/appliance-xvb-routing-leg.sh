# shellcheck shell=bash
# Bounded XvB actuation smoke for the throwaway KVM appliance. The appliance is
# intentionally unsynchronised, so this injects the controller's existing switch
# method rather than pretending a PPLNS share or routed hashrate exists.

_xvb_payload() { # <mode> -> base64 Python that actuates then reads the live route
    case "$1" in P2POOL | XVB) ;; *) return 2 ;; esac
    printf '%s\n' "import asyncio, json" "from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient" \
        "from mining_dashboard.config.config import PROXY_API_PORT, PROXY_AUTH_TOKEN, PROXY_HOST" \
        "from mining_dashboard.service.storage_service import StateManager" \
        "from mining_dashboard.service.xvb.algo_service import AlgoService" \
        "async def main():" \
        "    state = StateManager()" \
        "    client = XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN)" \
        "    await AlgoService(state, client, None).switch_miners('$1')" \
        "    pools = client.get_config().get('pools', [])" \
        "    print(json.dumps({'mode': state.get_xvb_stats().get('current_mode'), 'pools': [{'enabled': p.get('enabled'), 'tor': bool(p.get('socks5'))} for p in pools]}))" \
        "asyncio.run(main())" |
        base64 | tr -d '\n'
}

_xvb_guest_python() { _ssh "printf %s '$1' | base64 -d | podman exec -i dashboard python3 -"; }

_xvb_proxy_ready_payload() {
    printf '%s\n' "import sys" "from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient" \
        "from mining_dashboard.config.config import PROXY_API_PORT, PROXY_AUTH_TOKEN, PROXY_HOST" \
        "cfg = XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN).get_config()" \
        "sys.exit(0 if isinstance(cfg, dict) else 1)" |
        base64 | tr -d '\n'
}

# xmrig-proxy is held stopped by the sync gate (#35) until this leg starts it, fresh, one line
# above the actuation call. Its container's own healthcheck (#904, docker-compose.yml) gates
# nothing and gets there in ~1s once the process is up (job 1141), so it cannot stand in for this
# wait; algo_service.switch_miners swallows a not-yet-listening API as a silent, logged no-op (its
# get_config returns falsy, so it never calls update_config and never touches state) — exactly the
# shape job 629 hit: mode stayed null and pools stayed the single-entry startup config, because the
# switch never ran. Poll the SAME get_config() call switch_miners depends on, so "ready" means what
# the actuator actually needs, not just an open port.
#
# The gate is a one-way latch that only releases once the chain(s) fully sync — never true on this
# throwaway appliance — so it re-asserts the stop every UPDATE_INTERVAL cycle (30s default,
# data_gates.py) for as long as we wait. A single start before this loop loses that race outright:
# jobs 701 and 717 both died to it, one before the API ever answered, one a second after it did.
# Re-issue the start on every poll (a no-op once already running) so the gate's periodic stop is
# answered within one 2s poll instead of costing the whole wait.
#
# 60s was too tight for the gate's own cycle, not for the proxy: job 1141's guest journal shows
# xmrig-proxy's healthcheck reporting healthy within ~1s of every single start, but the gate-driven
# stop at 00:52:26.735Z was not followed by a restart until 00:53:25.423Z — a single ~59s outage
# that alone swallowed nearly the whole bounded wait, because xmrig-proxy's compose entry depends
# on p2pool's own restart finishing first (com.docker.compose.depends_on=p2pool:service_started).
# 150s gives one such worst-case gap room to happen and still leave a live window for the poll.
_xvb_wait_for_proxy_api() { # -> 0 once the proxy answers a real get_config()
    local deadline payload
    payload="$(_xvb_proxy_ready_payload)"
    deadline=$(($(date +%s) + ${XVB_PROXY_READY_TIMEOUT:-150}))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        _ssh "podman start xmrig-proxy >/dev/null 2>&1"
        _xvb_guest_python "$payload" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

_xvb_real_tor_fetch() {
    local payload
    payload="$(base64 <"$SCRIPT_DIR/../integration/lib/xvb-egress-probe.py" | tr -d '\n')"
    _xvb_guest_python "$payload"
}

# #2726 (job 1194): a Tor circuit read-timing out against a third-party host says nothing about the
# stack, so retry. Each attempt runs the whole audit-hook probe: a retry never passes non-Tor egress.
_xvb_real_tor_fetch_retry() {
    _xvb_real_tor_fetch || { sleep 15 && _xvb_real_tor_fetch; } || { sleep 15 && _xvb_real_tor_fetch; }
}

# The last guest-side stderr _ssh captured, folded onto one line for a verdict message. Throwing
# this away is why #2321 was filed off job 442 with no diagnostic: the row said the actuator failed
# and the guest's own traceback — the only thing that says whether the leg or the product is at
# fault — died with the redirect.
_xvb_guest_stderr() {
    tr -d '\r' <"${SSH_ERR:-/dev/null}" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ';'
}

# Tor reports healthy only at bootstrap TAG=done (build/tor/healthcheck.sh) — the product's own
# definition of "can route". The stats request below is a REAL clearnet fetch through that SOCKS,
# so firing it the moment the containers appear raced a Tor that was still bootstrapping: jobs 264,
# 276 and 520 all died there while the same runs proved Tor healthy minutes later (#2253).
_xvb_wait_for_tor() { # -> 0 once tor is healthy; on timeout echoes the last status it read
    local deadline status=""
    deadline=$(($(date +%s) + ${XVB_TOR_READY_TIMEOUT:-300}))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status="$(_ssh "podman inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' tor" 2>/dev/null | tr -d '\r\n')"
        [ "$status" = healthy ] && return 0
        sleep 5
    done
    printf '%s' "${status:-unreadable}"
    return 1
}

_xvb_route_is() { # <route-json> <mode> <tor-routed: true|false>
    printf '%s' "$1" | jq -e --arg mode "$2" --argjson tor "$3" \
        '.mode == $mode and .pools[0].enabled == true and .pools[0].tor == $tor and .pools[1].enabled == false' \
        >/dev/null 2>&1
}

# #2708 (job 1172): a single-shot restore that hits a transient ConnectTimeout leaves the guest
# routed to XvB for the rest of the phase — every downstream row that depends on p2pool actually
# mining then fails the same way. Retry with the same confirmation the XvB switch already gets,
# instead of trusting (or silently swallowing) the first answer.
_xvb_restore_p2pool() { # -> pools JSON on stdout once P2POOL is confirmed live, empty + rc 1 on timeout
    local deadline pools
    deadline=$(($(date +%s) + ${XVB_RESTORE_TIMEOUT:-30}))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        pools="$(_xvb_guest_python "$(_xvb_payload P2POOL)")"
        if [ -n "$pools" ] && _xvb_route_is "$pools" P2POOL false; then
            printf '%s' "$pools"
            return 0
        fi
        sleep 2
    done
    return 1
}

# Both directions of the transition this issue exists to observe. Every red row returns 1 on the
# spot; the caller puts the guest back either way, so an early return cannot strand the proxy.
_xvb_routing_actuation() {
    local pools
    pools="$(_xvb_guest_python "$(_xvb_payload XVB)")"
    if [ -z "$pools" ]; then
        bad "controller actuator could not switch the live proxy to XvB (guest: $(_xvb_guest_stderr))"
        return 1
    fi
    if ! _xvb_route_is "$pools" XVB true; then
        bad "bounded controller injection did not leave XvB as the live Tor-routed proxy route (route: $pools)"
        return 1
    fi
    ok "bounded controller injection moved the live proxy to Tor-routed XvB"
    pools="$(_xvb_restore_p2pool)"
    if [ -z "$pools" ]; then
        bad "controller actuator could not restore the live proxy to P2Pool (guest: $(_xvb_guest_stderr))"
        return 1
    fi
    ok "bounded controller injection restored the live proxy to P2Pool"
}

# NOT a subshell body: ok/bad must count in the harness's own PASS/FAIL, and a bare `return` after
# bad() returns printf's 0 — between them a red leg read as a clean one and the caller never saw it.
phase_provision_xvb_routing() {
    local rc=0 tor_status
    info "provision leg — bounded XvB routing injection"
    if ! tor_status="$(_xvb_wait_for_tor)"; then
        bad "guest Tor never reported bootstrapped within ${XVB_TOR_READY_TIMEOUT:-300}s (last health: $tor_status) — the real XvB stats request was never made"
        return 1
    fi
    if _xvb_real_tor_fetch_retry; then
        ok "XvB stats request reached the real endpoint through the guest Tor SOCKS only"
    else
        bad "XvB stats request did not complete through the guest Tor SOCKS only (guest: $(_xvb_guest_stderr))"
        return 1
    fi
    _ssh "podman start xmrig-proxy >/dev/null" || {
        bad "held xmrig-proxy could not start for the bounded XvB actuator injection (guest: $(_xvb_guest_stderr))"
        return 1
    }
    if ! _xvb_wait_for_proxy_api; then
        bad "xmrig-proxy API never answered within ${XVB_PROXY_READY_TIMEOUT:-150}s of starting — the actuator was never attempted"
        _ssh "podman stop -t 5 xmrig-proxy >/dev/null 2>&1" || true
        return 1
    fi
    _xvb_routing_actuation || rc=1
    # Put the guest back the way the fresh appliance holds it (#35): re-assert P2POOL when the
    # actuation bailed mid-transition, so the fourteen rows after this one do not run against a
    # dashboard still persisting XVB, then stop the proxy again. #2708: the retry+confirm loop
    # already ran once inside the actuation, so a bare `|| true` here would repeat the very
    # silent-swallow that issue exists to kill — a fallback restore that also fails is a counted,
    # named diagnostic instead, so nothing downstream mistakes a still-misrouted guest for a clean one.
    if [ "$rc" -ne 0 ]; then
        _xvb_restore_p2pool >/dev/null ||
            bad "guest left routed to XvB after the leg failed — P2POOL restore did not confirm within ${XVB_RESTORE_TIMEOUT:-30}s (guest: $(_xvb_guest_stderr))"
    fi
    _ssh "podman stop -t 5 xmrig-proxy >/dev/null 2>&1" || true
    return "$rc"
}

_xvb_self_test() {
    local f=0 payload real_guest_python
    # #2712 (job 1141): a single gate-driven xmrig-proxy outage ran ~59s, so the wait's own default
    # must stay wide enough to survive one — this is a source check, not a timed run, because a real
    # 150s wait has no place in a unit self-test. Both defaults (the wait's own and the row message's)
    # have to move together or the failure message misreports what the leg actually waited for.
    declare -f _xvb_wait_for_proxy_api | grep -q ':-150' &&
        declare -f phase_provision_xvb_routing | grep -q ':-150' || {
        printf 'xvb self-test: proxy-ready default drifted below the #2712 evidence floor (150s)\n' >&2
        f=$((f + 1))
    }
    # A function redefined inside this self-test REPLACES the one global definition — there is no
    # lexical scoping to fall back on, and `unset -f` removes it rather than restoring it. Saved
    # here so the dedicated proxy-readiness drill below can run the REAL _xvb_guest_python (through
    # a stubbed _ssh) after the case-driven tests have overridden it for their own JSON responses.
    real_guest_python="$(declare -f _xvb_guest_python)"
    local decoded
    payload="$(_xvb_payload XVB)"
    decoded="$(printf '%s' "$payload" | base64 -d)"
    # The KEY NAME is checked here because nothing downstream can see it: every case below stubs
    # _xvb_guest_python, so the payload's own dict lookup never runs and a wrong key reads exactly
    # like a working one. That is not hypothetical — the payload shipped reading .get('mode') for
    # five bench rounds, and StateManager stores the field as xvb["current_mode"]
    # (storage_service.py), so the row reported null no matter what the actuator did.
    [ -n "$payload" ] && [ -n "$(_xvb_payload P2POOL)" ] &&
        printf '%s' "$decoded" | grep -q 'XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN)' &&
        printf '%s' "$decoded" | grep -q "get_xvb_stats().get('current_mode')" &&
        ! _xvb_payload SPLIT >/dev/null || {
        printf 'xvb self-test: actuator payload shape\n' >&2
        f=$((f + 1))
    }

    # Drive the REAL leg, one inverted assertion at a time. A source grep would pass on a leg whose
    # rows never reach the harness's counters, which is exactly the defect this replaced: the rows
    # must be counted HERE, in the caller's own PASS/FAIL, and the leg must return non-zero.
    local PASS=0 FAIL=0 XVBT_FETCH_FAILS=0 XVBT_FETCH_CALLS XVBT_START_RC=0 XVBT_XVB_JSON="" XVBT_P2P_JSON=""
    local XVBT_TOR_HEALTH=healthy XVB_TOR_READY_TIMEOUT=300
    local XVBT_PROXY_READY_RC=0 XVB_PROXY_READY_TIMEOUT=1 XVB_RESTORE_TIMEOUT=1
    local xvb_ok='{"mode":"XVB","pools":[{"enabled":true,"tor":true},{"enabled":false,"tor":false}]}'
    local p2p_ok='{"mode":"P2POOL","pools":[{"enabled":true,"tor":false},{"enabled":false,"tor":false}]}'
    ok() { PASS=$((PASS + 1)); }
    bad() { FAIL=$((FAIL + 1)); }
    info() { :; }
    sleep() { command sleep 0.05; } # the polls' own pacing, shortened so the self-test does not idle
    _ssh() {
        case "$1" in
        *"podman inspect"*" tor") printf '%s\n' "$XVBT_TOR_HEALTH" ;;
        *"podman start"*) return "$XVBT_START_RC" ;;
        esac
        return 0
    }
    XVBT_FETCH_CALLS="$(mktemp)"
    _xvb_real_tor_fetch() { printf x >>"$XVBT_FETCH_CALLS" && [ "$(wc -c <"$XVBT_FETCH_CALLS")" -gt "$XVBT_FETCH_FAILS" ]; }
    _xvb_guest_python() { # answers the mode the leg actually asked the guest to switch to
        case "$(printf '%s' "$1" | base64 -d 2>/dev/null)" in
        *"switch_miners('XVB')"*) printf '%s' "$XVBT_XVB_JSON" ;;
        *"switch_miners('P2POOL')"*) printf '%s' "$XVBT_P2P_JSON" ;;
        *"get_config()"*) return "$XVBT_PROXY_READY_RC" ;;
        esac
    }
    _xvb_case() { # <label> <want-pass> <want-fail> <want-rc>
        local rc=0
        PASS=0 FAIL=0
        phase_provision_xvb_routing >/dev/null 2>&1 || rc=$?
        [ "$PASS" = "$2" ] && [ "$FAIL" = "$3" ] && [ "$rc" = "$4" ] || {
            printf 'xvb self-test: %s — pass=%s want %s, fail=%s want %s, rc=%s want %s\n' \
                "$1" "$PASS" "$2" "$FAIL" "$3" "$rc" "$4" >&2
            f=$((f + 1))
        }
    }

    XVBT_XVB_JSON="$xvb_ok" XVBT_P2P_JSON="$p2p_ok"
    _xvb_case "a clean transition reports three green rows and rc 0" 3 0 0

    # #2708 (job 1172): a restore that hits one transient ConnectTimeout and then succeeds must NOT
    # strand the guest on XvB — the call has to retry until it confirms P2Pool, not trust (or
    # silently swallow) the first answer. A single-shot restore fails this case outright.
    local p2p_calls
    p2p_calls="$(mktemp)"
    _xvb_guest_python() {
        case "$(printf '%s' "$1" | base64 -d 2>/dev/null)" in
        *"switch_miners('XVB')"*) printf '%s' "$XVBT_XVB_JSON" ;;
        *"switch_miners('P2POOL')"*)
            printf 'x' >>"$p2p_calls"
            [ "$(wc -c <"$p2p_calls")" -ge 2 ] && printf '%s' "$p2p_ok"
            ;;
        *"get_config()"*) return "$XVBT_PROXY_READY_RC" ;;
        esac
    }
    _xvb_case "a restore that times out once and then succeeds is NOT a red row" 3 0 0
    rm -f "$p2p_calls"
    _xvb_guest_python() {
        case "$(printf '%s' "$1" | base64 -d 2>/dev/null)" in
        *"switch_miners('XVB')"*) printf '%s' "$XVBT_XVB_JSON" ;;
        *"switch_miners('P2POOL')"*) printf '%s' "$XVBT_P2P_JSON" ;;
        *"get_config()"*) return "$XVBT_PROXY_READY_RC" ;;
        esac
    }

    # #2253: the leg must WAIT for Tor rather than race it, and must say so when it never arrives.
    # The REAL wait runs in every case here; only the guest's answer and the deadline are stubbed.
    XVBT_TOR_HEALTH=starting XVB_TOR_READY_TIMEOUT=1
    _xvb_case "a Tor that never bootstraps is a counted red row before any request is made" 0 1 1
    XVBT_TOR_HEALTH=healthy XVB_TOR_READY_TIMEOUT=300
    # #2726 (job 1194): one Tor read timeout then an answer is green; three misses stay red.
    : >"$XVBT_FETCH_CALLS" && XVBT_FETCH_FAILS=1
    _xvb_case "a real XvB request that times out once and then answers is NOT a red row" 3 0 0
    : >"$XVBT_FETCH_CALLS" && XVBT_FETCH_FAILS=99
    _xvb_case "an unreachable real XvB request over guest Tor is a counted red row" 0 1 1
    [ "$(wc -c <"$XVBT_FETCH_CALLS")" = 3 ] || { echo "xvb self-test: fetch not tried 3 times" >&2 && f=$((f + 1)); }
    XVBT_FETCH_FAILS=0 && rm -f "$XVBT_FETCH_CALLS"
    XVBT_START_RC=1
    _xvb_case "a held xmrig-proxy that will not start is a counted red row" 1 1 1
    XVBT_START_RC=0
    # Job 629's own cause: xmrig-proxy started but its API never answered before the actuator was
    # tried, so the switch silently no-opped. That must be a counted red row on its own, before the
    # actuator ever runs — not the actuator's "could not switch" row, which would misname the cause.
    XVBT_PROXY_READY_RC=1
    _xvb_case "an xmrig-proxy API that never answers after starting is a counted red row" 1 1 1
    XVBT_PROXY_READY_RC=0
    # #2321's own row: the actuator answering nothing must be RED and must reach the summary.
    XVBT_XVB_JSON=""
    _xvb_case "an actuator that cannot switch the live proxy to XvB is a counted red row" 1 1 1
    XVBT_XVB_JSON='{"mode":"P2POOL","pools":[{"enabled":true,"tor":true},{"enabled":false,"tor":false}]}'
    _xvb_case "a dashboard left persisting P2POOL after the XvB switch is a counted red row" 1 1 1
    XVBT_XVB_JSON='{"mode":"XVB","pools":[{"enabled":true,"tor":false},{"enabled":false,"tor":false}]}'
    _xvb_case "an XvB route that is not Tor-routed is a counted red row" 1 1 1
    XVBT_XVB_JSON='{"mode":"XVB","pools":[{"enabled":true,"tor":true},{"enabled":true,"tor":false}]}'
    _xvb_case "a second pool left enabled beside XvB is a counted red row" 1 1 1
    XVBT_XVB_JSON='{"mode":"XVB","pools":[{"enabled":false,"tor":true},{"enabled":false,"tor":false}]}'
    _xvb_case "an XvB route whose own pool is disabled is a counted red row" 1 1 1
    XVBT_XVB_JSON="$xvb_ok"

    # fail=2 below: the restore itself fails (counted once inside the actuation), and the phase-level
    # fallback restore — now also retrying/confirming instead of a silent `|| true` (#2708) — retries
    # against the SAME broken stub, times out too, and is a second, distinct counted red row: the
    # guest really is left misrouted, not just the first attempt.
    XVBT_P2P_JSON=""
    _xvb_case "an actuator that cannot restore P2Pool is a counted red row, twice over" 2 2 1
    XVBT_P2P_JSON='{"mode":"XVB","pools":[{"enabled":true,"tor":false},{"enabled":false,"tor":false}]}'
    _xvb_case "a dashboard left persisting XVB after the restore is a counted red row, twice over" 2 2 1
    XVBT_P2P_JSON='{"mode":"P2POOL","pools":[{"enabled":true,"tor":true},{"enabled":false,"tor":false}]}'
    _xvb_case "a P2Pool route left Tor-routed is a counted red row, twice over" 2 2 1
    XVBT_P2P_JSON='{"mode":"P2POOL","pools":[{"enabled":false,"tor":false},{"enabled":false,"tor":false}]}'
    _xvb_case "a restored P2Pool route whose own pool is disabled is a counted red row, twice over" 2 2 1

    # The wait must RIDE OUT the not-yet-healthy answers rather than read the first one as a
    # verdict — a single-shot check is the #2253 race itself, and it would pass every case above.
    # The poll reads the guest inside a command substitution, so the tally has to outlive a
    # subshell: a plain counter variable increments in the child and reads 0 here, forever.
    local answers
    answers="$(mktemp)"
    _ssh() {
        printf 'x' >>"$answers"
        [ "$(wc -c <"$answers")" -ge 3 ] && printf 'healthy\n' || printf 'starting\n'
    }
    if ! XVB_TOR_READY_TIMEOUT=300 _xvb_wait_for_tor >/dev/null || [ "$(wc -c <"$answers")" -lt 3 ]; then
        printf 'xvb self-test: the Tor wait gave up on a guest that became healthy (answers=%s)\n' \
            "$(wc -c <"$answers")" >&2
        f=$((f + 1))
    fi
    rm -f "$answers"
    # And the timed-out wait must hand back the LAST status it read: on a guest whose Tor never
    # arrives, that string is the entire diagnostic.
    local last_status
    _ssh() { printf 'starting\n'; }
    if last_status="$(XVB_TOR_READY_TIMEOUT=1 _xvb_wait_for_tor)"; then
        printf 'xvb self-test: the Tor wait reported ready for a guest that never bootstrapped\n' >&2
        f=$((f + 1))
    elif [ "$last_status" != starting ]; then
        printf 'xvb self-test: the timed-out Tor wait did not name the last health it read (%s)\n' "$last_status" >&2
        f=$((f + 1))
    fi
    unset -f sleep

    # Same property, for the proxy-readiness wait: it must ride out a not-yet-listening API rather
    # than read the first failed get_config() as a verdict. Restore the REAL _xvb_guest_python (see
    # real_guest_python above) so only _ssh answers, exercising the actual payload plumbing.
    eval "$real_guest_python"
    sleep() { command sleep 0.02; }
    local proxy_answers
    proxy_answers="$(mktemp)"
    _ssh() {
        printf 'x' >>"$proxy_answers"
        [ "$(wc -c <"$proxy_answers")" -ge 3 ] && return 0 || return 1
    }
    if ! XVB_PROXY_READY_TIMEOUT=300 _xvb_wait_for_proxy_api || [ "$(wc -c <"$proxy_answers")" -lt 3 ]; then
        printf 'xvb self-test: the proxy-API wait gave up on a guest that came up (answers=%s)\n' \
            "$(wc -c <"$proxy_answers")" >&2
        f=$((f + 1))
    fi
    rm -f "$proxy_answers"
    _ssh() { return 1; }
    if XVB_PROXY_READY_TIMEOUT=1 _xvb_wait_for_proxy_api; then
        printf 'xvb self-test: the proxy-API wait reported ready for a guest that never answered\n' >&2
        f=$((f + 1))
    fi

    # #1998 regression (jobs 701, 717): the sync gate (#35) re-stops xmrig-proxy every cycle on
    # this unsynced appliance, so a wait that starts it once and only polls loses that race. Prove
    # the wait keeps re-asserting the start itself, not just the one the caller made before it —
    # a single start call here would time out having never answered, same as the case above.
    local start_calls=0
    _ssh() {
        case "$1" in
        *"podman start"*) start_calls=$((start_calls + 1)) ;;
        esac
        return 1
    }
    XVB_PROXY_READY_TIMEOUT=1 _xvb_wait_for_proxy_api
    if [ "$start_calls" -lt 2 ]; then
        printf 'xvb self-test: the proxy-API wait does not re-assert the start against the sync gate (#1998), only asserted %s time(s)\n' \
            "$start_calls" >&2
        f=$((f + 1))
    fi
    unset -f sleep

    unset -f ok bad info _ssh _xvb_real_tor_fetch _xvb_guest_python _xvb_case
    [ "$f" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    _xvb_self_test || exit 1
    echo "appliance-xvb-routing-leg self-test passed"
fi
