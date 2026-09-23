# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# The stack phase (#2062): tests/integration/run.sh (the DIY gate, what release-gate.yml runs)
# has never once run against the appliance runtime — podman through the docker shim, read-only
# root, the stack in /data/pithead, the control runner as a systemd unit. Every other appliance
# phase provisions in LOCAL node mode, and a scratch KVM disk can never hold a synced chain, so
# `provision`'s own miner sits behind the sync gate forever (#35) and the DIY gate's destructive
# phases — fault injection, hot-apply scenarios — have no live appliance coverage.
#
# Remote-node mode breaks that: the guest points at the bench's ALREADY-SYNCED monerod (and,
# optionally, an already-synced Tari node) from the very first wizard submit, so p2pool clears the
# sync gate in minutes rather than never and the guest can actually mine. This is the first live
# remote-node coverage on either channel (#1446 tracks the DIY gate's own zero routine coverage).
#
# Two DIY-gate invocations run here, and they are what docs/dev/testing-strategy.md § J's parity
# matrix (#2062) credits this phase with over `provision`: a non-destructive `--check`, then
# `--lifecycle --fault-injection --hardening --auth-fail-closed` against remote-main-secure-tari —
# the remote-safe end of the 15-scenario config matrix, and the appliance channel's first live
# coverage of each. Two further rows from that matrix are NOT driven here, because this guest
# cannot satisfy their inputs; the call site below (`phase_stack`) carries the measured reasons:
# the `monero.mode=local` scenario needs a seeded chain (#2443), and the XvB routing smoke's
# Tor-isolation probe fails on this channel while discarding its own diagnostics (#2444).

# Shape the wizard's served config for remote-node mode. Mirrors provision_browser_config
# (tests/os/provision-browser-submit.sh) but for the Both-role remote-node answers instead of the
# all-local defaults, and reuses remote_node_proposal's endpoint shaping
# (tests/os/appliance-config-approval-leg.sh) rather than re-deriving it.
# $1 served config, $2 monero host, $3 rpc port, $4 zmq port, $5 monero username, $6 monero
# password, $7 tari host (empty means tari.mode=off, #1855), $8 tari grpc port.
stack_browser_config() {
    local cfg th="${7:-}" grpc="${8:-0}"
    # local_miner is left untouched at the wizard's own served default (enabled: true,
    # dashboard/mining_dashboard/wizard_config.py) rather than forced — a real appliance mines
    # with its own CPU by default, remote-node or not. Job 397 measured that default adding a
    # "local-miner" topology node the DIY gate's canonical-node-set assertion has never seen,
    # because the DIY bench's own persistent config happens to carry it disabled; that is a gap
    # in the assertion's expected list, filed separately, not a config choice for this phase to
    # suppress by diverging from the wizard's default.
    # xvb.enabled stays true even though no invocation here drives XvB routing today: it is the
    # baseline the #2444 row will need the moment that probe is readable enough to run from this
    # phase, and holding it keeps this guest byte-identical to the one job 633 passed against, so
    # that job stays a valid comparison for the next run rather than a differently-configured one.
    cfg=$(printf '%s' "$1" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" \
        '.monero.wallet_address = $m | .tari.wallet_address = $t | .p2pool.pool = "mini" |
         .xvb.enabled = true') || return 1
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
    # The DIY gate's own SSH defaults to ssh-agent/default identities (tests/integration/run.sh's
    # IT_SSH_OPTS carries no -i); the KVM guest only trusts the os battery's test key ($KEY,
    # baked in via PITHEAD_TEST_SSH_PUBKEY), so it must be named explicitly with --identity.
    "$SCRIPT_DIR/../integration/run.sh" --host "root@$ip" --identity "$KEY" --dir /data/pithead --workers 1 "$@" >"$out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "DIY gate vs. appliance channel: $label"
    else
        # The full capture, not a truncated tail: a one-line summary here cannot distinguish
        # "p2pool never got a merge-mining client" from "the client is up and Tari refused it"
        # from a dozen other same-named-but-differently-caused assertion failures, and every one
        # of those needs a different fix. This flows into the same kvm-<phase>.log artifact the
        # rest of the battery already writes through, so it costs nothing to keep.
        bad "DIY gate vs. appliance channel: $label (exit $rc)"
        sed 's/\x1b\[[0-9;]*m//g' "$out"
        # The DIY gate's own per-scenario capture (lib.sh:capture_artifacts) writes status/doctor/
        # compose/api-state into results/<scenario>/ on THIS host, and bench-ci collects fixed paths
        # only — so job 497 could not answer "what did `pithead status` actually say" for a leg that
        # failed on a status wait (#2062). Route them through this phase's own stdout, which already
        # tees into the collected kvm-<phase>.log. Already redacted at the point they were written;
        # logs.txt is skipped (200 container-log lines) and each file is bounded.
        local f
        for f in "$SCRIPT_DIR/../integration/results"/*/{status,doctor,compose-ps}.txt \
            "$SCRIPT_DIR/../integration/results"/*/api-state.json; do
            [ -f "$f" ] || continue
            info "  [$label] --- ${f#*results/} ---"
            sed 's/\x1b\[[0-9;]*m//g' "$f" | head -n 60
        done
    fi
    # The merge-mining round-trip's row rides along on a pass too: it is the one row whose verdict
    # (a chain_id read from the Tari node, #1397/#2326) is this channel's evidence on its own.
    grep -a -e 'of which:' -e '(#1397)' "$out" | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
        info "  [$label] ${line#*ITEST] }"
    done
    rm -f "$out"
    return "$rc"
}

# Provision a remote-node coordinator guest (#2062) from an ALREADY-BUILT image: boot it, submit
# the remote-node wizard config, wait for the credentials handoff, wait for the stack to release
# on /api/state, then wait for dashboard+caddy+p2pool to actually be running. Leaves $ip at the
# guest; sets dash_user/dash_pass (module-global on purpose — every caller reads them straight off
# this call, the same convention $ip already uses). Two callers now (#2063's rig share leg is the
# second), which is what earns this its own function rather than living inline in phase_stack.
# rc 1 = reported via bad(), the caller decides what that costs it.
_provision_remote_node_coordinator() { # <image> <monero-host> <rpc> <zmq> <user> <password> <tari-host> <grpc>
    local img="$1" mh="$2" rpc="$3" zmq="$4" mu="$5" mp="$6" th="$7" grpc="$8"
    _vm_boot_disk "$img" && _wait_ssh 240 || {
        bad "coordinator guest never answered SSH (ip: ${ip:-none})"
        return 1
    }
    ok "coordinator image boots ($ip)"

    local tries=0 token=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token ever appeared on the coordinator's console"
        return 1
    }
    _wait_setup_page 120 || {
        bad "coordinator wizard gate never served"
        return 1
    }

    local jar
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "coordinator token was not accepted"
        rm -f "$jar"
        return 1
    }
    grep -q "wizard_session" "$jar" || {
        bad "coordinator auth returned no session cookie"
        rm -f "$jar"
        return 1
    }

    wizard_state_poll "$ip" "$jar" '.config // empty' || {
        bad "coordinator wizard never served a config to shape ($WIZ_STATE_WHY)"
        rm -f "$jar"
        return 1
    }
    local cfg scode sbody
    cfg=$(stack_browser_config "$WIZ_STATE" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc") || {
        bad "coordinator remote-node config could not be shaped"
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
        bad "coordinator remote-node config submit did not return 200 (got ${scode:-none}: $(tr -d '\n' <"$sbody" | cut -c1-500))"
        rm -f "$jar" "$sbody"
        return 1
    }
    rm -f "$sbody"
    if [ -n "$th" ]; then
        ok "coordinator: remote-node config submitted (monero.mode=remote, tari.mode=remote)"
    else
        ok "coordinator: remote-node config submitted (monero.mode=remote, tari.mode=off, #1855)"
    fi

    local handoff_body="" htries=0
    while [ "$htries" -lt 24 ]; do
        handoff_body=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$handoff_body" | grep -q '"password"' && break
        sleep 5
        htries=$((htries + 1))
    done
    [ "$htries" -lt 24 ] || {
        bad "no credentials handoff appeared on the coordinator's page"
        rm -f "$jar"
        return 1
    }
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    ok "coordinator: handoff acknowledged — provisioning released"

    dash_user=$(printf '%s' "$handoff_body" | jq -r '.username // "admin"' 2>/dev/null)
    dash_pass=$(printf '%s' "$handoff_body" | jq -r '.password // ""' 2>/dev/null)

    # "Release on /api/state": the dashboard's own live state must answer before anything that
    # reads it too (the DIY gate, or #2063's share leg) has anything to drive.
    local deadline=$(($(date +%s) + 900)) released=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        curl -sSk -u "$dash_user:$dash_pass" -m 5 "https://$ip/api/state" 2>/dev/null | jq -e '.' >/dev/null 2>&1 && {
            released=1
            break
        }
        sleep 10
    done
    [ "$released" -eq 1 ] || {
        bad "coordinator /api/state never answered — provisioning did not release the stack"
        return 1
    }
    ok "coordinator: /api/state answers — provisioning released the stack"

    # p2pool takes noticeably longer than dashboard+caddy to report ready (image pull, its own
    # startup sequence) — job 454 (#2062) measured --check running against a guest whose p2pool
    # container hadn't started yet, six minutes after dashboard+caddy both had, failing every
    # p2pool-dependent assertion (container up, workers online, stratum hashes, merge-mining) for
    # a reason that had nothing to do with any of them. Wait for it explicitly rather than let the
    # DIY gate's own first invocation discover it missing.
    local deadline2=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline2" ]; do
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        if [[ "$names" == *dashboard* && "$names" == *caddy* && "$names" == *p2pool* ]]; then
            break
        fi
        sleep 15
    done
    if [[ "$names" == *dashboard* && "$names" == *caddy* && "$names" == *p2pool* ]]; then
        ok "coordinator: containers are running (podman: $names)"
    else
        bad "coordinator containers never came up (running: '${names:-none}')"
        return 1
    fi
}

phase_stack() {
    local mh="${PITHEAD_OS_MONERO_NODE_HOST:-}" rpc="${PITHEAD_OS_MONERO_RPC_PORT:-}" zmq="${PITHEAD_OS_MONERO_ZMQ_PORT:-}"
    local mu="${PITHEAD_OS_MONERO_NODE_USERNAME:-}" mp="${PITHEAD_OS_MONERO_NODE_PASSWORD:-}"
    local th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}"
    info "phase: stack (#2062 — the DIY gate, tests/integration/run.sh, against a remote-node appliance guest)"
    if [ -z "$mh" ] || [ -z "$rpc" ] || [ -z "$zmq" ]; then
        it_skip_phase "stack" "no reserved remote Monero node for this bench — set PITHEAD_OS_MONERO_NODE_HOST, PITHEAD_OS_MONERO_RPC_PORT and PITHEAD_OS_MONERO_ZMQ_PORT to run it" missing
        return
    fi

    local img
    img=$(_build_image stack-v1) || {
        bad "stack: image build failed (/tmp/os-fault-build.log)"
        return 1
    }
    _provision_remote_node_coordinator "$img" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc" || return 1

    # The DIY gate itself: a non-destructive read, then the destructive phases the appliance
    # channel has never run — its first live coverage of each (#2062). The two parity rows this
    # guest cannot satisfy are named, with their own issues, after the invocations below.
    #
    # Every invocation below names --scenario (or, for --check, returns before the matrix is
    # even reached). Without one, tests/integration/run.sh's own default is to iterate its FULL
    # 15-scenario matrix first — almost all of it monero.mode=local, which this remote-node-only
    # guest can only run by starting a local monerod from scratch each time. That cost over two
    # hours and starved xvb-routing-smoke of its own budget the first time this ran for real
    # (#2062); the local matrix is the DIY gate's own job on its own bench, not this phase's.
    local remote_extra=(--remote-monero-host "$mh" --remote-monero-rpc-port "$rpc" --remote-monero-zmq-port "$zmq")
    [ -z "$th" ] || remote_extra+=(--remote-tari-host "$th")
    # --check needs the remote endpoints too, not just the scenario runs: run-state.sh reads
    # $REMOTE_MONERO_HOST with no fallback for the ZMQ probe, so without them it dials an empty
    # host and reports connect-refused against a node that is in fact publishing. Job 397 proved
    # it both ways in one run — the same two ZMQ rows passed in the scenario leg, which carries
    # these flags, and failed in this one, which did not.
    _stack_run_integration "check (non-destructive live-state assertion)" --check "${remote_extra[@]}"
    _stack_run_integration "lifecycle, fault-injection, hardening, auth-fail-closed" \
        --scenario remote-main-secure-tari "${remote_extra[@]}" \
        --lifecycle --fault-injection --hardening --auth-fail-closed
    # Two more parity rows from #2062's table are deliberately NOT driven here, because this guest
    # cannot satisfy their inputs and a row that cannot pass proves nothing where it sits:
    #   * remote-tari-main-secure sets monero.mode=local (tests/integration/scenarios.sh), so it
    #     starts a local monerod with an empty database on a scratch virtual disk. Job 510 measured
    #     the whole sync-gated half of that scenario red for that one reason — synced, both ZMQ
    #     rows, the sync panel, stratum hashes — while the SAME job's remote-node invocations
    #     passed all of them minutes earlier. Needs a guest with a seeded chain: #2443.
    #   * --xvb-routing-smoke's Tor-isolation probe fails on this channel and discards its own
    #     output, so the red is unreadable and cannot be acted on from here: #2444.
}
