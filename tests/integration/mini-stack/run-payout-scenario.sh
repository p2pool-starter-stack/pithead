# shellcheck shell=bash
# Payout confirmation (#2267), sourced by run-mini-stack.sh (issue #1258's split-out pattern —
# this scenario outgrew the parent file's budget). Uses that script's compose()/c_ok/c_bad/
# sink_requests/wait_sink/wait_dashboard_api and PASS/FAIL counters; not standalone-executable.

fake_ctl() { # <container> <port> <json>
    compose exec -T "$1" python3 -c '
import sys
import urllib.request

request = urllib.request.Request(
    f"http://127.0.0.1:{sys.argv[1]}/control",
    data=sys.argv[2].encode(),
    headers={"Content-Type": "application/json"},
)
print(urllib.request.urlopen(request, timeout=5).read().decode())
' "$2" "$3"
}
set_wallet() { fake_ctl fake-wallet-rpc 18082 "$1" >/dev/null || c_bad "set Monero wallet transfers" "control POST failed"; }
set_tari_wallet() { fake_ctl fake-tari-wallet 18153 "$1" >/dev/null || c_bad "set Tari wallet transfers" "control POST failed"; }
wallet_calls() { fake_ctl fake-wallet-rpc 18082 '{}' | jq -r '.calls'; }
tari_wallet_calls() { fake_ctl fake-tari-wallet 18153 '{}' | jq -r '.calls'; }
wallet_status() { # <monero|tari>
    compose exec -T dashboard python3 -c 'import json,sys,urllib.request; s=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/state",timeout=5)); print(json.dumps(s["earnings"]["tari_confirmed" if sys.argv[1]=="tari" else "confirmed"]))' "$1"
}
wait_wallet_field() { # <chain> <field> <expected>
    local end=$(( $(date +%s) + 20 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        [ "$(wallet_status "$1" | jq -r ".${2}" 2>/dev/null)" = "$3" ] && return 0
        sleep 1
    done
    return 1
}
wallet_min_height() { fake_ctl fake-wallet-rpc 18082 '{}' | jq -r '.last_min_height'; }

# Payouts poll every 10th collection cycle; at UPDATE_INTERVAL=2 that's a 20s poll interval, so
# the deadline must cover at least two of them to catch a poll that lands just after the replay.
wait_min_height() { # wait_min_height <expected> [timeout]
    local want="$1" timeout="${2:-50}" end
    end=$(($(date +%s) + timeout))
    while :; do
        [ "$(wallet_min_height)" = "$want" ] && return 0
        [ "$(date +%s)" -ge "$end" ] && return 1
        sleep 1
    done
}

wait_payout() { # wait_payout <chain> <amount> [timeout]
    local chain="$1" amount="$2" timeout="${3:-50}" end result
    end=$(($(date +%s) + timeout))
    while :; do
        result="$(
            compose exec -T dashboard python3 - "$chain" "$amount" <<'PY' 2>&1
import json
import sys
import urllib.request

chain, amount = sys.argv[1], float(sys.argv[2])
state = json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/state", timeout=5))
confirmed = state["earnings"]["confirmed" if chain == "monero" else "tari_confirmed"]
total = confirmed["xmr_all" if chain == "monero" else "xtm_all"]
if confirmed.get("enabled") and total == amount:
    print("OK")
PY
        )"
        [ "$result" = "OK" ] && {
            c_ok "$chain payout appears in /api/state"
            return 0
        }
        [ "$(date +%s)" -ge "$end" ] && {
            c_bad "$chain payout appears in /api/state" "$result"
            return 1
        }
        sleep 1
    done
}

# The payout webhook rides the same NOTIFY_WEBHOOK_URLS the alert-sink coverage in the parent
# script points at fake-sink (#2263), not fake-hc's separate event log — read the sink's own
# request log instead. fake_sink.py stores each POST body as a JSON-escaped *string*, so any raw
# text match has to know that escaping; decode the line instead and count only webhook posts whose
# event really is payout_confirmed. A decode failure prints nothing, and every caller below wants
# exactly 1, so it reads red rather than passing as a quiet zero.
payout_alert_count() {
    sink_requests | python3 -c '
import json, sys
rows = [json.loads(line) for line in sys.stdin if line.strip()]
print(sum(1 for r in rows if r["path"] == "/webhook" and json.loads(r["body"]).get("event") == "payout_confirmed"))
'
}
wallet_down_count() { # <monero|tari>
    sink_requests | python3 -c '
import json, sys
chain = sys.argv[1].title() + " payout wallet"
rows = [json.loads(line) for line in sys.stdin if line.strip()]
print(sum(1 for row in rows if row["path"] == "/webhook" and
          (body := json.loads(row["body"])).get("event") == "payout_wallet_down" and
          chain in body.get("text", "")))
' "$1"
}

# 12. Payout confirmation (#2267): drive each real wallet client through its network fake, then
# prove the persisted total is exposed by /api/state and the configured webhook saw one alert.
# Replaying the same payload must not add either a second total or a second alert; empty wallets
# remain enabled but invent nothing.
scenario_payout_confirmation() {
    # Restore the dashboard's default alert-sink wiring — the outage check just before this ran
    # it blanked to prove a disabled config makes no request.
    compose up -d --force-recreate dashboard >/dev/null 2>&1
    wait_dashboard_api

    log "scenario 12: payout confirmation reaches state and alerts exactly once"
    compose exec -T fake-sink sh -c ': > /tmp/requests.log'
    set_wallet '{"transfers":[{"txid":"a1","amount":250000000000,"height":100,"timestamp":1000}]}'
    wait_payout monero 0.25
    wait_sink "Monero payout fires one alert" 'payout_confirmed' 50
    if [ "$(payout_alert_count)" = 1 ]; then c_ok "Monero payout alert fired once"; else c_bad "Monero payout alert fired once" "got $(payout_alert_count)"; fi
    set_wallet '{"transfers":[{"txid":"a1","amount":250000000000,"height":100,"timestamp":1000}]}'
    wait_min_height 100
    if [ "$(payout_alert_count)" = 1 ] && [ "$(wallet_min_height)" = 100 ]; then c_ok "Monero payout replay fires no alert and seeds min_height"; else c_bad "Monero payout replay fires no alert and seeds min_height" "alerts=$(payout_alert_count), min_height=$(wallet_min_height)"; fi

    compose exec -T fake-sink sh -c ': > /tmp/requests.log'
    set_tari_wallet '{"transactions":[{"tx_id":7,"amount":2500000,"timestamp":1000,"mined_in_block_height":100}]}'
    wait_payout tari 2.5
    wait_sink "Tari payout fires one alert" 'payout_confirmed' 50
    if [ "$(payout_alert_count)" = 1 ]; then c_ok "Tari payout alert fired once"; else c_bad "Tari payout alert fired once" "got $(payout_alert_count)"; fi
    set_tari_wallet '{"transactions":[{"tx_id":7,"amount":2500000,"timestamp":1000,"mined_in_block_height":100}]}'
    sleep 22
    if [ "$(payout_alert_count)" = 1 ]; then c_ok "Tari payout replay fires no alert"; else c_bad "Tari payout replay fires no alert" "got $(payout_alert_count)"; fi
    set_wallet '{"transfers":[]}'
    set_tari_wallet '{"transactions":[]}'
    sleep 22
    empty_state="$(
        compose exec -T dashboard python3 - <<'PY' 2>&1
import json
import urllib.request

state = json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/state", timeout=5))
monero, tari = state["earnings"]["confirmed"], state["earnings"]["tari_confirmed"]
if monero.get("enabled") and tari.get("enabled") and monero.get("xmr_all") == 0.25 and tari.get("xtm_all") == 2.5:
    print("OK")
PY
    )"
    if [ "$empty_state" = OK ] && [ "$(payout_alert_count)" = 1 ]; then c_ok "empty wallets stay enabled and add nothing"; else c_bad "empty wallets stay enabled and add nothing" "$empty_state; alerts=$(payout_alert_count)"; fi

    # The wallet probes run every collection cycle, faster than the payout scan. Empty answers
    # remain reachable; a wrong address is explicit, and a stopped wallet becomes DOWN promptly.
    if [ "$(wallet_status monero | jq -r .reachable)" = true ] && [ "$(wallet_status tari | jq -r .reachable)" = true ]; then c_ok "empty payout scans remain reachable"; else c_bad "empty payout scans remain reachable" "wallet probe failed"; fi
    set_wallet '{"address":"wrong-monero"}'
    if wait_wallet_field monero address_match false && [ "$(wallet_status monero | jq -r .wallet_address)" = wrong-monero ]; then c_ok "Monero wrong wallet address is visible"; else c_bad "Monero wrong wallet address is visible" "$(wallet_status monero)"; fi
    set_tari_wallet '{"address":"wrong-tari"}'
    if wait_wallet_field tari address_match false && [ "$(wallet_status tari | jq -r .wallet_address)" = wrong-tari ]; then c_ok "Tari wrong wallet address is visible"; else c_bad "Tari wrong wallet address is visible" "$(wallet_status tari)"; fi
    if wait_wallet_field monero down true && wait_wallet_field tari down true &&
        [ "$(wallet_down_count monero)" = 1 ] && [ "$(wallet_down_count tari)" = 1 ]; then
        c_ok "each wrong payout wallet emits one alert edge"
    else
        c_bad "each wrong payout wallet emits one alert edge" "Monero=$(wallet_down_count monero), Tari=$(wallet_down_count tari)"
    fi
    set_wallet '{"address":"49iTestWalletPlaceholderXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"}'
    set_tari_wallet '{"address":"tari-test-wallet"}'
    if wait_wallet_field monero down false && wait_wallet_field tari address_match true && wait_wallet_field tari down false; then c_ok "both wallet addresses recover"; else c_bad "both wallet addresses recover" "$(wallet_status tari)"; fi
    set_wallet '{"address":"wrong-monero"}'
    set_tari_wallet '{"address":"wrong-tari"}'
    if wait_wallet_field monero down true && wait_wallet_field tari down true &&
        [ "$(wallet_down_count monero)" = 2 ] && [ "$(wallet_down_count tari)" = 2 ]; then
        c_ok "each wallet emits a new edge after recovery"
    else
        c_bad "each wallet emits a new edge after recovery" "Monero=$(wallet_down_count monero), Tari=$(wallet_down_count tari)"
    fi
    set_wallet '{"address":"49iTestWalletPlaceholderXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"}'
    set_tari_wallet '{"address":"tari-test-wallet"}'
    wait_wallet_field monero down false && wait_wallet_field tari down false
    compose stop fake-wallet-rpc >/dev/null
    compose stop fake-tari-wallet >/dev/null
    if wait_wallet_field monero down true && wait_wallet_field tari down true &&
        [ "$(wallet_status monero | jq -r .reachable)" = false ] &&
        [ "$(wallet_status tari | jq -r .reachable)" = false ]; then c_ok "stopped wallets turn earnings red"; else c_bad "stopped wallets turn earnings red" "$(wallet_status tari)"; fi
    compose start fake-wallet-rpc >/dev/null
    compose start fake-tari-wallet >/dev/null

    if compose --profile wallet-health up -d tari-wallet-broken; then
        health_deadline=$(( $(date +%s) + 15 ))
        while [ "$(docker inspect -f '{{.State.Health.Status}}' itest-tari-wallet-broken 2>/dev/null)" != unhealthy ] &&
            [ "$(date +%s)" -lt "$health_deadline" ]; do sleep 1; done
        if [ "$(docker inspect -f '{{.State.Health.Status}}' itest-tari-wallet-broken 2>/dev/null)" = unhealthy ] &&
            compose --profile wallet-health logs tari-wallet-broken 2>&1 | grep -q 'not readable'; then
            c_ok "broken Tari wallet secret yields unhealthy gRPC health"
        else
            c_bad "broken Tari wallet secret yields unhealthy gRPC health" "health never turned unhealthy after secret rejection"
        fi
        compose --profile wallet-health stop tari-wallet-broken >/dev/null
    else
        c_bad "broken Tari wallet secret yields unhealthy gRPC health" "could not start health row"
    fi

    # Control: disabling payout confirmation constructs neither wallet client nor any wallet dial.
    set_wallet '{"transfers":[],"reset_calls":true}'
    set_tari_wallet '{"transactions":[],"reset_calls":true}'
    PAYOUT_CONFIRM_ENABLED=false TARI_PAYOUT_CONFIRM_ENABLED=false compose up -d --force-recreate dashboard >/dev/null 2>&1
    sleep 22
    if [ "$(wallet_calls)" = 0 ] && [ "$(tari_wallet_calls)" = 0 ]; then c_ok "disabled payout confirmation dials no wallet"; else c_bad "disabled payout confirmation dials no wallet" "Monero=$(wallet_calls), Tari=$(tari_wallet_calls)"; fi
}
