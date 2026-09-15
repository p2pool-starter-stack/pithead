# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# The stack phase (#2062): tests/integration/run.sh (the DIY gate, what release-gate.yml runs)
# has never once run against the appliance runtime — podman through the docker shim, read-only
# root, the stack in /data/pithead, the control runner as a systemd unit. Every other appliance
# phase provisions in LOCAL node mode, and a scratch KVM disk can never hold a synced chain, so
# `provision`'s own miner sits behind the sync gate forever (#35) and the DIY gate's destructive
# phases — fault injection, hot-apply scenarios, XvB routing — have no live appliance coverage.
#
# Remote-node mode breaks that: the guest points at the bench's ALREADY-SYNCED monerod (and,
# optionally, an already-synced Tari node) from the very first wizard submit, so p2pool clears the
# sync gate in minutes rather than never and the guest can actually mine. This is the first live
# remote-node coverage on either channel (#1446 tracks the DIY gate's own zero routine coverage).
#
# docs/dev/testing-strategy.md § J's parity matrix (#2062) names exactly what this phase adds over
# `provision`: the 15-scenario config matrix's remote-safe subset, fault injection, hardening,
# auth-fail-closed, and XvB routing — all against the appliance channel for the first time.
# SCRIPT_DIR is the runner's own directory (tests/os), not this file's: run.sh *sources* the
# phase files, so BASH_SOURCE never points here. One `..` reaches tests/, which is where the
# integration runner lives; two reached the repo root and every assertion below died with
# exit 127 before it ran (#2254).
STACK_INTEGRATION_RUN="$SCRIPT_DIR/../integration/run.sh"
[ -x "$STACK_INTEGRATION_RUN" ] || {
    echo "stack: integration runner not found or not executable at $STACK_INTEGRATION_RUN" >&2
    return 1 2>/dev/null || exit 1
}

# Shape the wizard's served config for remote-node mode. Mirrors provision_browser_config
# (tests/os/provision-browser-submit.sh) but for the Both-role remote-node answers instead of the
# all-local defaults, and reuses remote_node_proposal's endpoint shaping
# (tests/os/appliance-config-approval-leg.sh) rather than re-deriving it.
# $1 served config, $2 monero host, $3 rpc port, $4 zmq port, $5 monero username, $6 monero
# password, $7 tari host (empty means tari.mode=off, #1855), $8 tari grpc port.
stack_browser_config() {
    local cfg th="${7:-}" grpc="${8:-0}"
    cfg=$(printf '%s' "$1" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" \
        '.monero.wallet_address = $m | .tari.wallet_address = $t | .p2pool.pool = "mini" |
         .local_miner.enabled = true | .xvb.enabled = true') || return 1
    if [ -n "$th" ]; then
        remote_node_proposal "$cfg" "$2" "$3" "$4" "$5" "$6" "$th" "$grpc"
    else
        printf '%s' "$cfg" | jq -c --arg h "$2" --argjson rpc "$3" --argjson zmq "$4" --arg u "$5" --arg p "$6" \
            '.monero.mode = "remote" | .monero.remote = {host: $h, rpc_port: $rpc, zmq_port: $zmq} |
             .monero.node_username = $u | .monero.node_password = $p | .tari.mode = "off"'
    fi
}

# Run one tests/integration/run.sh invocation against the provisioned guest, fold its pass/fail
# into this battery, and surface its skip accounting (tests/integration/lib/skip-accounting.sh) —
# the harness's three named buckets, by-design / covered / missing — in THIS battery's own
# summary, so an appliance-channel skip reads as a counted, classified gap rather than silence.
_stack_run_integration() { # <label> <extra args...>
    local label="$1" out rc
    shift
    out=$(mktemp)
    # shellcheck disable=SC2154  # shared through the assembled runner scope
    "$STACK_INTEGRATION_RUN" --host "root@$ip" --dir /data/pithead --workers 1 "$@" >"$out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "DIY gate vs. appliance channel: $label"
    else
        bad "DIY gate vs. appliance channel: $label (exit $rc; tail: $(tail -5 "$out" | tr '\n' ' ' | cut -c1-300))"
    fi
    grep -a 'of which:' "$out" | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
        info "  [$label] ${line#*ITEST] }"
    done
    rm -f "$out"
    return "$rc"
}

phase_stack() {
    local mh="${PITHEAD_OS_MONERO_NODE_HOST:-}" rpc="${PITHEAD_OS_MONERO_RPC_PORT:-}" zmq="${PITHEAD_OS_MONERO_ZMQ_PORT:-}"
    local mu="${PITHEAD_OS_MONERO_NODE_USERNAME:-}" mp="${PITHEAD_OS_MONERO_NODE_PASSWORD:-}"
    local th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}"
    info "phase: stack (#2062 — the DIY gate, tests/integration/run.sh, against a remote-node appliance guest)"
    if [ -z "$mh" ] || [ -z "$rpc" ] || [ -z "$zmq" ]; then
        info "stack phase SKIPPED (by-design): no reserved remote Monero node for this bench — set PITHEAD_OS_MONERO_NODE_HOST, PITHEAD_OS_MONERO_RPC_PORT and PITHEAD_OS_MONERO_ZMQ_PORT to run it"
        return
    fi

    local img
    img=$(_build_image stack-v1) || {
        bad "stack: image build failed (/tmp/os-fault-build.log)"
        return 1
    }
    _vm_boot_disk "$img" && _wait_ssh 240 || {
        bad "stack: guest never answered SSH (ip: ${ip:-none})"
        return 1
    }
    ok "stack image boots ($ip)"

    local tries=0 token=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "stack: no one-time token ever appeared on the console"
        return 1
    }
    _wait_setup_page 120 || {
        bad "stack: wizard gate never served"
        return 1
    }

    local jar
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "stack: token was not accepted"
        rm -f "$jar"
        return 1
    }
    grep -q "wizard_session" "$jar" || {
        bad "stack: auth returned no session cookie"
        rm -f "$jar"
        return 1
    }

    wizard_state_poll "$ip" "$jar" '.config // empty' || {
        bad "stack: wizard never served a config to shape ($WIZ_STATE_WHY)"
        rm -f "$jar"
        return 1
    }
    local cfg scode sbody
    cfg=$(stack_browser_config "$WIZ_STATE" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc") || {
        bad "stack: remote-node config could not be shaped"
        rm -f "$jar"
        return 1
    }
    sbody=$(mktemp)
    scode=$(curl -sSk -b "$jar" --data-urlencode "config=$cfg" --data-urlencode "auth_mode=auto" \
        "https://$ip/submit" -o "$sbody" -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        # /submit probes the reserved node's reachability synchronously (wizard_node_probe.py)
        # and 400s with the probe's own reason — surface it, not just the status code, since a
        # remote-node submit failure is far more often a bad host/port/firewall than bad JSON.
        bad "stack: remote-node config submit did not return 200 (got ${scode:-none}: $(tr -d '\n' <"$sbody" | cut -c1-500))"
        rm -f "$jar" "$sbody"
        return 1
    }
    rm -f "$sbody"
    if [ -n "$th" ]; then
        ok "stack: remote-node config submitted (monero.mode=remote, tari.mode=remote)"
    else
        ok "stack: remote-node config submitted (monero.mode=remote, tari.mode=off, #1855)"
    fi

    local handoff_body="" htries=0
    while [ "$htries" -lt 24 ]; do
        handoff_body=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$handoff_body" | grep -q '"password"' && break
        sleep 5
        htries=$((htries + 1))
    done
    [ "$htries" -lt 24 ] || {
        bad "stack: no credentials handoff appeared on the page"
        rm -f "$jar"
        return 1
    }
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    ok "stack: handoff acknowledged — provisioning released"

    local dash_user dash_pass
    dash_user=$(printf '%s' "$handoff_body" | jq -r '.username // "admin"' 2>/dev/null)
    dash_pass=$(printf '%s' "$handoff_body" | jq -r '.password // ""' 2>/dev/null)

    # "Release on /api/state": the dashboard's own live state must answer before the DIY gate
    # (which reads it too) has anything to drive.
    local deadline=$(($(date +%s) + 900)) released=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        curl -sSk -u "$dash_user:$dash_pass" -m 5 "https://$ip/api/state" 2>/dev/null | jq -e '.' >/dev/null 2>&1 && {
            released=1
            break
        }
        sleep 10
    done
    [ "$released" -eq 1 ] || {
        bad "stack: /api/state never answered — provisioning did not release the stack"
        return 1
    }
    ok "stack: /api/state answers — provisioning released the stack"

    local deadline2=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline2" ]; do
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "stack: containers are running (podman: $names)"
        ;;
    *)
        bad "stack: containers never came up (running: '${names:-none}')"
        return 1
        ;;
    esac

    # The DIY gate itself, staged as the ask lays out: a non-destructive read, then the
    # destructive phases the appliance channel has never run, then the remote-safe scenario
    # subset, then XvB routing — the appliance channel's first live coverage of each (#2062).
    _stack_run_integration "check (non-destructive live-state assertion)" --check
    _stack_run_integration "lifecycle, fault-injection, hardening, auth-fail-closed" \
        --lifecycle --fault-injection --hardening --auth-fail-closed
    local scn remote_extra=(--remote-monero-host "$mh" --remote-monero-rpc-port "$rpc" --remote-monero-zmq-port "$zmq")
    [ -z "$th" ] || remote_extra+=(--remote-tari-host "$th")
    for scn in remote-main-secure-tari remote-tari-main-secure; do
        _stack_run_integration "scenario $scn" --scenario "$scn" "${remote_extra[@]}"
    done
    # xvb.enabled=true was submitted above; a recent PPLNS share is NOT guaranteed on a scratch
    # guest whose remote node was only just pointed at — a fresh live-node coverage gap #2062
    # documents (docs/dev/testing-strategy.md § J), not a defect this phase can manufacture.
    _stack_run_integration "xvb routing smoke (first appliance-channel run)" \
        --safety-backup --xvb-routing-smoke
}
