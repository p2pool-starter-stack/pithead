# shellcheck shell=bash
#
# The browser-shaped wizard submit for phase_provision (#1846). Sourced by tests/os/run.sh;
# tests/stack/test-harness-tooling.sh drives `--self-test` (tier 1, no guest).
# What a person's browser sends is not the no-JS field form: wizard.mjs takes the page's own
# served config (/api/wizard-state .config — the reference merged with the last attempt), sets the
# operator's answers on the same paths the page uses, and POSTs it whole as `config=<JSON>`
# beside `auth_mode=auto` (the recommended "generate a strong password for me"). The old leg
# posted `monero_wallet=…&pool=…`, which build_config() turns into a config server-side, so the
# path the operator actually took — and the one that refused on Both — never ran through the
# gate. A sibling, not rows in run.sh, which sits at its 3423-line ceiling.
#
# $1 ip, $2 authenticated cookie jar, then any extra form fields (`disk=vda`, `wipe=data` — the
# installer's disk half rides beside the config) -> prints the HTTP status of /submit (or a short
# reason when the page never served a config), the same contract the inline curl had.
# Reads /api/wizard-state the way a person waits for a page: up to six reads 5 s apart, until the jq
# filter in $3 yields a value. One cold read at -m 5 is not a verdict (#1932), and a fixture
# control built on one reddens with one word (#1936). On a hit WIZ_STATE holds the value (a raw
# string, or compact JSON) and the return is 0; otherwise WIZ_STATE is empty, the return is 1, and
# WIZ_STATE_WHY names what the last read saw — status, curl's rc, the read count, the head of the
# body — so the log discriminates a refusal from a timeout from a non-JSON page.
wizard_state_poll() { # <ip> <jar> <jq-filter>
    local raw="" http="" crc=0 tries=0
    WIZ_STATE="" WIZ_STATE_WHY=""
    while [ "$tries" -lt 6 ]; do
        raw=$(curl -sSk -b "$2" -m 5 -w '\n%{http_code}' "https://$1/api/wizard-state" 2>/dev/null)
        crc=$?
        http=${raw##*$'\n'}
        raw=${raw%$'\n'*}
        WIZ_STATE=$(printf '%s' "$raw" | jq -rc "$3" 2>/dev/null)
        [ -n "$WIZ_STATE" ] && return 0
        tries=$((tries + 1))
        sleep 5
    done
    WIZ_STATE_WHY="http=${http:-none} curl=$crc after ${tries}x5s body=$(printf '%s' "$raw" | head -c 60 | tr -c '[:print:]' '?')"
    return 1
}
# #2076: the fake Telegram credentials this used to seed (PROVISION_FAKE_APPROVAL) are gone with
# the approval round-trip. Seeding them now would also FAIL the commit gate's closed-schema guard,
# since `telegram.control` is no longer a path in config.reference.json.
provision_browser_config() { # <served-config>
    printf '%s' "$1" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" --arg h "${PROVISION_DASHBOARD_HOST:-}" \
        '.monero.wallet_address = $m | .monero.mode = "local" | .tari.wallet_address = $t |
         .tari.mode = "local" | .p2pool.pool = "mini" | .local_miner.enabled = true |
         if $h != "" then .dashboard.host = $h else . end'
}
provision_browser_submit() { # <ip> <jar> [field=value]...
    local ip="$1" jar="$2" cfg extra=()
    shift 2
    for f in "$@"; do extra+=(--data-urlencode "$f"); done
    wizard_state_poll "$ip" "$jar" '.config // empty' || {
        printf 'no-served-config(%s)' "$WIZ_STATE_WHY"
        return 1
    }
    # The four answers the Both role gives on the page, on the page's own paths (wizard.mjs
    # FIELDS: monero.wallet_address, tari.wallet_address, p2pool.pool, local_miner.enabled).
    cfg=$(provision_browser_config "$WIZ_STATE") || {
        printf 'jq-failed'
        return 1
    }
    curl -sSk -b "$jar" --data-urlencode "config=$cfg" --data-urlencode "auth_mode=auto" "${extra[@]}" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null
}
# The page's own error line, for a red that names the refusal instead of a timeout. Empty when
# the page shows none (or cannot be reached).
provision_page_error() { # <ip> <jar>
    curl -sSk -b "$2" -m 5 "https://$1/api/wizard-state" 2>/dev/null | jq -r '.error // ""' 2>/dev/null
}
node_preflight_state_retained() { # <submit-response-json> <wizard-state-json> <expected-wallet>
    printf '%s' "$1" | jq -e '
        .error == "The node name did not resolve to an address." and
        .node_probe.ok == false and .node_probe.configured == 1 and .node_probe.probed == 1 and
        any(.node_probe.probes[]; .target == "tari" and .reason == "dns" and .ok == false)' >/dev/null &&
        printf '%s' "$2" | jq -e --arg m "$3" '
            .stage == "setup" and .config.monero.wallet_address == $m and
            .config.tari.remote.host == "unreachable.invalid"' >/dev/null
}
# This refusal is separate from later setup failure recovery: the protocol preflight stays on the
# form, retains safe answers, and publishes the exact failed Tari row. The caller then submits the
# corrected local choice; a post-validation setup fault has its own leg once that product seam lands.
provision_node_preflight_retention() { # <ip> <authenticated-cookie-jar>
    local ip="$1" jar="$2" state cfg code raw body
    state=$(curl -fsSk -b "$jar" -m 5 "https://$ip/api/wizard-state" 2>/dev/null) || return 1
    cfg=$(printf '%s' "$state" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" '
        .config | .monero.wallet_address = $m | .tari.wallet_address = $t |
        .tari.mode = "remote" | .tari.remote.host = "unreachable.invalid" |
        .tari.remote.grpc_port = 18142 | .p2pool.pool = "mini" | .local_miner.enabled = true') || return 1
    raw=$(curl -sSk -b "$jar" -m 20 --data-urlencode "config=$cfg" --data-urlencode "auth_mode=auto" \
        "https://$ip/submit" -w '\n%{http_code}' 2>/dev/null)
    code=${raw##*$'\n'}
    body=${raw%$'\n'*}
    state=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/wizard-state" 2>/dev/null)
    if [ "$code" = "400" ] && node_preflight_state_retained "$body" "$state" "$HARNESS_WALLET"; then
        ok "remote-node preflight refuses the unreachable Tari consumer and retains safe answers"
    else
        bad "remote-node preflight did not return the named Tari refusal with retained values (HTTP ${code:-none})"
        return 1
    fi
}
# POST a control request and follow its result through dashboard restarts.
dashboard_curl() {
    local auth="${DASH_USER}:${DASH_PASS}"
    case "$auth" in *$'\n'* | *$'\r'*) return 1 ;; esac
    auth=${auth//\\/\\\\}
    auth=${auth//\"/\\\"}
    curl --config <(printf 'user = "%s"\n' "$auth") "$@"
}
dashboard_control_request() { # <route> <json-body> [deadline-seconds]
    local route="$1" body="$2" deadline=$(($(date +%s) + ${3:-240})) out rid status
    out=$(dashboard_control_post "$route" "$body") || return
    rid=$(printf '%s' "$out" | jq -r '.id // ""' 2>/dev/null)
    [ -n "$rid" ] || return 1
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(printf '%s' "$out" | jq -r '.status // "pending"' 2>/dev/null) || status=pending
        case "$status" in
        pending | running | downloading | installing | "") ;;
        previewed) [ "$route" = preview ] && {
            printf '%s' "$out"
            return 0
        } ;;
        *)
            printf '%s' "$out"
            return 0
            ;;
        esac
        sleep 3
        out=$(dashboard_curl -sSk -m 8 "https://$ip/api/control/result?id=$rid" 2>/dev/null)
    done
    return 1
}
# The control runner's own answer, bounded, for a row whose evidence IS that answer (#2060).
# The #1966 rows reported a verdict and nothing else, so a red could not be read without a --keep
# guest. An empty result is its own sentence: `dashboard_control_request` returns nothing both
# when the POST was refused and when the request never left pending before its deadline, and a
# row that printed the same thing for that as for a rejected apply would hide the difference.
control_result_payload() { # <result-json>
    [ -n "$1" ] || {
        printf 'no result — the control request never returned (POST refused, or still pending at its deadline)'
        return 0
    }
    printf '%s' "$1" | jq -r '"status=\(.status // "none") error=\(.error // "none") id=\(.id // "none")"' 2>/dev/null ||
        printf 'unparseable result: %.200s' "$1"
}

phase_provision_control_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" live proposed preview result rid old peers code names archive pass archive_names
    live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) || {
        bad "post-provision control: live config could not be read"
        return
    }

    proposed=$(printf '%s' "$live" | jq -c '.dashboard.energy.cost_per_kwh = 0.17')
    preview=$(dashboard_control_request preview "$(dashboard_config_body "$proposed")")
    if printf '%s' "$preview" | jq -e '.status == "previewed" and .destructive == false and any(.changes[]; .flag == "INFO")' >/dev/null; then
        ok "post-provision benign setting previews as an ordinary committable change"
    else
        bad "post-provision benign setting did not produce an INFO preview"
        return
    fi
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id}')")
    live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null)
    if printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null &&
        printf '%s' "$live" | jq -e '.dashboard.energy.cost_per_kwh == 0.17' >/dev/null; then
        ok "post-provision benign setting applies through the dashboard control runner"
    else
        bad "post-provision benign setting did not land ($(control_result_payload "$result"); live cost_per_kwh=$(printf '%s' "${live:-null}" | jq -r '.dashboard.energy.cost_per_kwh // "unreadable"' 2>/dev/null || echo unreadable), want 0.17)"
        return
    fi
    # No re-read and no emptiness guard: reaching this line means the row above parsed $live as
    # JSON carrying 0.17, so it cannot be empty here. The `case` below is the real guard on the
    # value, and it reports rather than returning silently.
    old=$(printf '%s' "$live" | jq -r '.monero.out_peers // 48')
    case "$old" in *[!0-9]* | "" | ?????*)
        bad "post-provision approved setting returned an unsafe current value"
        return
        ;;
    esac
    if [ "$old" -lt 1 ] || [ "$old" -gt 1024 ]; then
        bad "post-provision approved setting returned an out-of-range current value"
        return
    fi
    [ "$old" -lt 1024 ] && peers=$((old + 1)) || peers=$((old - 1))
    proposed=$(printf '%s' "$live" | jq -c --argjson peers "$peers" '.monero.out_peers = $peers')
    preview=$(dashboard_control_request preview "$(dashboard_config_body "$proposed")")
    if printf '%s' "$preview" | jq -e '.status == "previewed" and .destructive == true and any(.changes[]; .flag == "CONFIRM")' >/dev/null; then
        ok "post-provision disruptive setting previews behind typed approval"
    else
        bad "post-provision disruptive setting was not classified CONFIRM"
        return
    fi
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id}')")
    if printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("type APPLY"))' >/dev/null; then
        ok "post-provision disruptive apply is refused without the typed approval"
    else
        bad "post-provision disruptive apply crossed the approval gate without APPLY"
        return
    fi
    preview=$(dashboard_control_request preview "$(dashboard_config_body "$proposed")")
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')")
    live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null)
    if printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null &&
        printf '%s' "$live" | jq -e --argjson peers "$peers" '.monero.out_peers == $peers' >/dev/null; then
        ok "post-provision disruptive setting applies with typed approval"
    else
        bad "post-provision approved setting did not land ($(control_result_payload "$result"); live out_peers=$(printf '%s' "${live:-null}" | jq -r '.monero.out_peers // "unreadable"' 2>/dev/null || echo unreadable), want $peers)"
        return
    fi
    proposed=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null |
        jq -c --argjson old "$old" '.monero.out_peers = $old')
    preview=$(dashboard_control_request preview "$(dashboard_config_body "$proposed")")
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')")
    printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null || bad "post-provision approved-setting cleanup failed"

    phase_provision_diagnostics_regressions "$DASH_USER" "$DASH_PASS"

    result=$(dashboard_control_request backup '{}' 360)
    rid=$(printf '%s' "$result" | jq -r '.id // ""')
    archive=$(mktemp)
    code=$(dashboard_curl -sSk -m 30 -o "$archive" -w '%{http_code}' \
        "https://$ip/api/control/backup-download?id=$rid" 2>/dev/null)
    pass=$(printf '%s' "$result" | jq -r '.passphrase // ""')
    archive_names=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass fd:3 \
        -in "$archive" 2>/dev/null 3< <(printf '%s' "$pass") | tar -tz 2>/dev/null) || archive_names=""
    if printf '%s' "$result" | jq -e '.status == "applied" and (.passphrase | length > 0) and (.archive | length > 0)' >/dev/null &&
        [ "$code" = "200" ] && printf '%s\n' "$archive_names" | grep -qx 'data/pithead/config.json' &&
        printf '%s\n' "$archive_names" | grep -qx 'data/pithead/.env'; then
        ok "dashboard backup decrypts with its one-time passphrase and contains the stack identity"
    else
        bad "dashboard backup did not produce a downloadable encrypted archive"
    fi
    rm -f "$archive"
    names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
    code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
    case "$names:$code" in
    *dashboard*caddy*:2?? | *dashboard*caddy*:3?? | *dashboard*caddy*:401 | *dashboard*caddy*:403 | \
        *caddy*dashboard*:2?? | *caddy*dashboard*:3?? | *caddy*dashboard*:401 | *caddy*dashboard*:403)
        ok "stack and dashboard recover after the dashboard-driven backup (HTTP $code)"
        ;;
    *) bad "stack/dashboard did not recover after backup (running: ${names:-none}; HTTP ${code:-none})" ;;
    esac
}
_recovery_self_test() {
    local response='{"error":"The node name did not resolve to an address.","node_probe":{"ok":false,"configured":1,"probed":1,"probes":[{"target":"tari","reason":"dns","ok":false}]}}'
    local state='{"stage":"setup","config":{"monero":{"wallet_address":"wallet"},"tari":{"remote":{"host":"unreachable.invalid"}}}}'
    node_preflight_state_retained "$response" "$state" wallet || return 1
    ! node_preflight_state_retained "${response/\"dns\"/\"protocol\"}" "$state" wallet || return 1
    ! node_preflight_state_retained "$response" "${state/\"setup\"/\"failed\"}" wallet || return 1
    ! node_preflight_state_retained "$response" "${state/\"wallet\"/\"lost\"}" wallet || return 1
    local HARNESS_WALLET=wallet HARNESS_TARI=tari PROVISION_DASHBOARD_HOST=fixture-box cfg
    cfg=$(provision_browser_config '{"telegram":{"bot_token":"","chat_id":""}}') || return 1
    # #2076: the shaper seeds wallets, mode and host and touches NOTHING under .telegram — an empty
    # bot_token must come back empty rather than seeded with a fake approval identity.
    printf '%s' "$cfg" | jq -e '.dashboard.host == "fixture-box" and .monero.wallet_address == "wallet" and
        .telegram.bot_token == "" and (.telegram | has("control") | not)' >/dev/null || return 1
    # Idempotent, and it never invents Telegram state on a config that already carries some.
    [ "$(provision_browser_config "$cfg")" = "$cfg" ] || return 1
    printf '%s' "$(provision_browser_config '{"telegram":{"bot_token":"operator-secret","chat_id":"-1"}}')" |
        jq -e '.telegram.bot_token == "operator-secret"' >/dev/null || return 1
    # The control-runner payload (#2060): a rejected apply, a runner that answered nothing, and a
    # body that is not JSON must each write a sentence only they write.
    case "$(control_result_payload '{"status":"rejected","error":"type APPLY","id":"r1"}')" in
    'status=rejected error=type APPLY id=r1') ;;
    *) return 1 ;;
    esac
    case "$(control_result_payload '')" in *'never returned'*) ;; *) return 1 ;; esac
    case "$(control_result_payload '{"status":"applied"')" in *unparseable*) ;; *) return 1 ;; esac
    case "$(control_result_payload '{"id":"r2"}')" in 'status=none error=none id=r2') ;; *) return 1 ;; esac
    echo "provision-browser-submit self-test: preflight retention, submit-shaping and control-payload controls passed"
}

# --- self-test (#1936) -----------------------------------------------------------------------
#
# The curl shim answers timeout, no-config, HTML-error and delayed-config shapes. The last case
# proves the shim answered: no real read serves `.error` = x.
_wsp_case() { # <name> <got> <want>
    [ "$2" = "$3" ] && return 0
    printf '  FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"
    return 1
}
_wsp_self_test() {
    local f=0 calls shape
    calls=$(mktemp)
    sleep() { :; }
    curl() { # the body, a newline, the status — what -w '\n%{http_code}' prints; rc per shape
        # the URL — the last argument — so a case can assert the route
        echo "${!#}" >>"$calls"
        case "$shape" in
        timeout) printf '\n000' && return 28 ;;
        noconfig) printf '{"error":"x"}\n200' ;;
        html) printf '<html><body>502 Bad Gateway\001 from an upstream that never answered in time</body></html>\n502' ;;
        late)
            [ "$(wc -l <"$calls")" -ge 3 ] || { printf '\n000' && return 28; }
            printf '{"config":{"monero":{"wallet_address":"4ABCDEFGHIJ"}}}\n\n200'
            ;;
        esac
    }
    shape=timeout
    : >"$calls"
    wizard_state_poll h j '.config // empty' && f=$((f + 1))
    _wsp_case timeout "$WIZ_STATE|$WIZ_STATE_WHY|$(wc -l <"$calls" | tr -d ' ')" "|http=000 curl=28 after 6x5s body=|6" || f=$((f + 1))
    shape=noconfig
    : >"$calls"
    wizard_state_poll h j '.config // empty' && f=$((f + 1))
    _wsp_case noconfig "$WIZ_STATE_WHY" 'http=200 curl=0 after 6x5s body={"error":"x"}' || f=$((f + 1))
    shape=html
    : >"$calls"
    _wsp_case html "$(provision_browser_submit h j)" 'no-served-config(http=502 curl=0 after 6x5s body=<html><body>502 Bad Gateway? from an upstream that never ans)' || f=$((f + 1))
    shape=late
    : >"$calls"
    wizard_state_poll h j '.config // empty' || f=$((f + 1))
    _wsp_case late "$WIZ_STATE|$WIZ_STATE_WHY|$(wc -l <"$calls" | tr -d ' ')" '{"monero":{"wallet_address":"4ABCDEFGHIJ"}}||3' || f=$((f + 1))
    shape=late
    : >"$calls"
    wizard_state_poll h j '.config.monero.wallet_address // empty' || f=$((f + 1))
    _wsp_case wallet "$WIZ_STATE" 4ABCDEFGHIJ || f=$((f + 1))
    shape=noconfig
    : >"$calls"
    wizard_state_poll h j '.error' || f=$((f + 1))
    _wsp_case control "$WIZ_STATE" x || f=$((f + 1))
    # The route: the wizard registers /api/wizard-state and no /api/state (#1932); a shim that
    # never reads its arguments would pass with either, so the URL the poll asked is asserted once.
    _wsp_case route "$(tail -n 1 "$calls")" 'https://h/api/wizard-state' || f=$((f + 1))
    rm -f "$calls"
    if [ "$f" -gt 0 ]; then
        printf '#1936 wizard-state-poll self-test FAILED: %s checks\n' "$f"
        return 1
    fi
    printf '#1936 wizard-state-poll self-test passed\n'
}
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--self-test" ]; then
    set -uo pipefail # what tests/os/run.sh runs the helpers under
    # shellcheck source=tests/os/appliance-config-approval-leg.sh
    . "$(cd "$(dirname "$0")" && pwd)/appliance-config-approval-leg.sh"
    # shellcheck source=tests/os/setup-failure-recovery-leg.sh
    . "$(cd "$(dirname "$0")" && pwd)/setup-failure-recovery-leg.sh"
    # shellcheck source=tests/integration/lib/mergemine-probe.sh
    . "$(cd "$(dirname "$0")/../integration/lib" && pwd)/mergemine-probe.sh"
    _wsp_self_test && _recovery_self_test && _setup_failure_self_test && _approval_self_test
    exit $?
fi
