# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
#
# Live alert-egress leg (#2266): drive `pithead test-alert` (#2265) through the real Tor SOCKS
# proxy to prove a configured sink still accepts our traffic FROM A TOR EXIT — the one bit tiers
# 1-3 (fakes, #2263; the SOCKS unit tests, #2264) cannot buy, because a fake never refuses us.
# #424 is the recorded case: a stuck Tor guard silently took out Healthchecks, Telegram and XvB
# together.
#
# One leg per sink, each gated on its own operator-supplied IT_* credential (bench-only, never a
# CI default) — an absent credential records a "missing" skip naming the sink (#1083), never a
# silent pass. A sink that answers with anything but success is the third party's call, not ours
# (#424's framing): it is a REFUSAL, counted and named on its own, and it must never turn IT_FAIL
# red — the flake policy quarantines this class, it does not retry it.
#
# Healthchecks is excluded from `test-alert` itself (dashboard/mining_dashboard/service/notify/test_alert.py: "a ping
# moves the dead-man switch"), so its leg calls the SAME production HealthchecksClient directly
# instead of duplicating its HTTP logic here.
#
# No credential value is ever interpolated into a command string or printed: env values travel to
# the box only through push_config's stdin-over-ssh JSON (never a shell argument), and every
# verdict below names the sink, never the token/url/chat id. TELEGRAM_BOT_TOKEN, NTFY_URL,
# WEBHOOK_URLS and HEALTHCHECKS_PING_URL already match redact()'s KEY=value vocabulary
# (tests/integration/lib.sh); TELEGRAM_CHAT_ID does not, deliberately (selftest-redact-vocab.sh's
# MUST_SURVIVE: "a routing id", not a credential) and this leg never echoes it either.

IT_ALERT_REFUSED=0
IT_ALERT_REFUSED_NAMES=""
it_alert_refused() { # <leg> <reason>
    IT_ALERT_REFUSED=$((IT_ALERT_REFUSED + 1))
    IT_ALERT_REFUSED_NAMES="${IT_ALERT_REFUSED_NAMES}\n    - ${1} — ${2}"
    it_warn "THIRD-PARTY REFUSAL ${1}: ${2} (an environment fact, not a stack failure — #424)"
}

_alert_egress_overlay() {
    local overlay="$BASELINE_CONFIG"
    if [ -n "${IT_TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${IT_TELEGRAM_CHAT_ID:-}" ]; then
        overlay="$(printf '%s' "$overlay" | jq --arg t "$IT_TELEGRAM_BOT_TOKEN" --arg c "$IT_TELEGRAM_CHAT_ID" \
            '.telegram.enabled=true | .telegram.bot_token=$t | .telegram.chat_id=$c')"
    fi
    if [ -n "${IT_NTFY_URL:-}" ]; then
        overlay="$(printf '%s' "$overlay" | jq --arg u "$IT_NTFY_URL" --arg t "${IT_NTFY_TOKEN:-}" \
            '.notifications.ntfy.url=$u | .notifications.ntfy.token=$t')"
    fi
    if [ -n "${IT_WEBHOOK_URLS:-}" ]; then
        overlay="$(printf '%s' "$overlay" | jq --arg w "$IT_WEBHOOK_URLS" '.notifications.webhooks=[$w]')"
    fi
    if [ -n "${IT_HEALTHCHECKS_PING_URL:-}" ]; then
        overlay="$(printf '%s' "$overlay" | jq --arg p "$IT_HEALTHCHECKS_PING_URL" '.healthchecks.ping_url=$p')"
    fi
    printf '%s' "$overlay"
}

# Parse one `<label>: PASS|FAIL (...)|not configured` line out of test-alert's stdout.
_alert_egress_verdict() { # <test-alert output> <label> <leg-name>
    local line
    line="$(printf '%s\n' "$1" | grep -E "^${2}: ")" || true
    case "$line" in
    "${2}: PASS") it_pass "$3" ;;
    "${2}: FAIL"*) it_alert_refused "$3" "${line#*FAIL }" ;;
    *) it_fail "$3" "test-alert reported [${line:-no line for $2}] for a sink this leg just configured" ;;
    esac
}

run_alert_egress_smoke() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="alert-egress"
    echo ""
    it_log "── live alert egress over Tor (#2266) ────────────────"
    local overlay have_dial=0 out

    if [ -z "${IT_TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${IT_TELEGRAM_CHAT_ID:-}" ]; then
        it_skip_leg "alert egress: Telegram (#2266)" "no IT_TELEGRAM_BOT_TOKEN/IT_TELEGRAM_CHAT_ID — configure Telegram on the bench to prove reachability over Tor" "missing"
    else
        have_dial=1
    fi
    if [ -z "${IT_NTFY_URL:-}" ]; then
        it_skip_leg "alert egress: ntfy (#2266)" "no IT_NTFY_URL — configure an ntfy sink on the bench to prove reachability over Tor" "missing"
    else
        have_dial=1
    fi
    if [ -z "${IT_WEBHOOK_URLS:-}" ]; then
        it_skip_leg "alert egress: webhook (#2266)" "no IT_WEBHOOK_URLS — configure a webhook sink on the bench to prove reachability over Tor" "missing"
    else
        have_dial=1
    fi
    if [ -z "${IT_HEALTHCHECKS_PING_URL:-}" ]; then
        it_skip_leg "alert egress: Healthchecks (#2266)" "no IT_HEALTHCHECKS_PING_URL — configure a Healthchecks ping URL on the bench to prove reachability over Tor" "missing"
    fi

    [ "$have_dial" -eq 1 ] || [ -n "${IT_HEALTHCHECKS_PING_URL:-}" ] || return 0

    overlay="$(_alert_egress_overlay)"
    if ! push_config "$overlay" || ! pithead apply -y 2>&1 | redact >"$OUT_DIR/alert-egress-enable.apply.log" || ! wait_status_ok 240; then
        it_fail "alert-egress leg converged the live stack onto the operator-supplied sink config" "see $OUT_DIR/alert-egress-enable.apply.log"
    else
        if [ "$have_dial" -eq 1 ]; then
            out="$(rx "docker exec dashboard python3 -m mining_dashboard.service.notify.test_alert" 2>/dev/null)"
            if [ -n "${IT_TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${IT_TELEGRAM_CHAT_ID:-}" ]; then
                _alert_egress_verdict "$out" "Telegram" "alert egress: Telegram sink answered over Tor (#2266)"
            fi
            [ -z "${IT_WEBHOOK_URLS:-}" ] || _alert_egress_verdict "$out" "Webhook" "alert egress: webhook sink answered over Tor (#2266)"
            [ -z "${IT_NTFY_URL:-}" ] || _alert_egress_verdict "$out" "ntfy" "alert egress: ntfy sink answered over Tor (#2266)"
        fi
        if [ -n "${IT_HEALTHCHECKS_PING_URL:-}" ]; then
            if rx "docker exec dashboard python3 -c 'from mining_dashboard.service.notify.healthchecks import HealthchecksClient; import sys; sys.exit(0 if HealthchecksClient.from_config().ping() else 1)'" >/dev/null 2>&1; then
                it_pass "alert egress: Healthchecks ping answered over Tor (#2266)"
            else
                it_alert_refused "alert egress: Healthchecks ping over Tor (#2266)" "ping rejected or unreachable"
            fi
        fi
    fi

    push_config "$BASELINE_CONFIG"
    pithead apply -y >/dev/null 2>&1
    wait_status_ok 240 || true
}
