# `support-bundle` (#77 phase 1): most support is log collection — one command gathers what a
# report needs into a chmod-600 tarball the operator reviews before sharing. Read-only; nothing
# leaves the box. Secrets are redacted at the source: config via the control channel's masking
# (render_masked_config), .env by a survivor allowlist over the rendered population
# (bundle_redact_env, #1631), container logs by argv position — p2pool echoes its --rpc-login, both
# wallet addresses and the service onion on launch, the leak class this exists to stop. The
# membership of that class was drawn too narrowly until #1585; add to bundle_redact_log, not to a
# second list.

PITHEAD_ENV_SURVIVOR_KEYS="CADDY_LOG_DIR CLEARNET_STATE_DIR COMPOSE_PROFILES CONTROL_DIR
DASHBOARD_CHECK_UPDATES DASHBOARD_CONTROL_ENABLED DASHBOARD_DATA_DIR DASHBOARD_EXPOSE_PUBLIC_IP
DASHBOARD_FAIL_CLOSED DASHBOARD_MODE DASHBOARD_ONION_CLIENT_AUTH DASHBOARD_ONION_ENABLED DASHBOARD_SECURE
DONATION_ENABLED DONATION_PERCENT DONATION_TOR_ENABLED
DASHBOARD_TZ DEPLOYMENT_COMPLETED HASHRATE_DROP_MINUTES HASHRATE_DROP_THRESHOLD_PCT HOST_PORT
MONERO_CLEARNET_SYNC MONERO_DATA_DIR MONERO_MEM_LIMIT MONERO_OUT_PEERS MONERO_PREP_THREADS
MONERO_PRUNE MONERO_RPC_BIND MONERO_RPC_PORT MONERO_WALLET_RPC_URL MONERO_ZMQ_BIND MONERO_ZMQ_PORT
NETWORK_PREFIX NETWORK_SUBNET NOTIFY_TOR P2POOL_CLEARNET P2POOL_DATA_DIR P2POOL_FLAGS P2POOL_PORT
P2POOL_URL PAYOUT_CONFIRM_ENABLED PAYOUT_SCAN_HEIGHT PITHEAD_TLS_DIR PROXY_API_PORT
PITHEAD_DIAG_CONTAINERS PROXY_DONATE_LEVEL PROXY_STRATUM_TLS PROXY_TLS_DIR STRATUM_BIND STRATUM_PORT TARI_CLEARNET_SYNC
TARI_DATA_DIR TARI_GRPC_BIND TARI_MEM_LIMIT TARI_MODE TARI_PAYOUT_CONFIRM_ENABLED TARI_REQUIRED
TARI_WALLET_BIRTHDAY TARI_WALLET_GRPC_ADDRESS TARI_WALLET_SECRET_FILE TELEGRAM_COMMANDS_ENABLED
TELEGRAM_DAILY_SUMMARY_TIME TELEGRAM_LEVEL TOR_AUTO_HEAL TOR_COMPOSE_PROFILES TOR_DATA_DIR
TOR_EGRESS_FIREWALL WALLET_RPC_USERNAME XMRIG_API_AUTH XMRIG_API_PORT XVB_DONATION_LEVEL
XVB_ENABLED XVB_POOL_URL XVB_TOR_ENABLED
DONATION_ENABLED DONATION_PERCENT DONATION_TOR_ENABLED"

# Everything not in PITHEAD_ENV_SURVIVOR_KEYS is redacted — credentials, wallet and view keys,
# onion identity, capability URLs and the handful of addressing fields the ruling classified as
# topology rather than structure (MONERO_NODE_HOST, MONERO_RPC_URL, TARI_GRPC_ADDRESS, HOST_IP).
#
# The allowlist also governs which LINES are read (#2414), and every ambiguity fails closed. A
# hand-edited .env keeps the previous value commented out above the live one, so an assignment
# behind `#`, indentation, `export` or spaces around `=` is classified like a live one: the prefix
# and key stay, the value goes. A survivor keeps its value up to the first unquoted `#`, which
# becomes `# [redacted]`; a survivor value that opens a quote it never closes, or holds any `=`
# (a second `KEY=` joined by any separator, or none), is redacted. A comment that is not an
# assignment keeps its prose, but every `KEY=` inside it that is not a survivor with an `=`-free
# value loses the rest of the line. Any other line is redacted whole, since it cannot
# be classified. Plain `[ \t]` rather than `[[:space:]]`: older mawk has no POSIX classes.
# The Tari explorer URL (#2464) may carry a token, so the bundle's config masks it on top of the
# control channel's masked copy. Only here: in CONTROL_SECRET_PATHS the commit gate would read the
# mask as an edit to TARI_EXPLORER_URL and refuse unrelated dashboard changes (KVM job 1397).
bundle_mask_config() { jq 'if (.tari.explorer_url // "") != "" then .tari.explorer_url = {"__secret__": true} else . end'; }

bundle_redact_env() {
    awk -v survivors="${PITHEAD_ENV_SURVIVOR_KEYS//$'\n'/ }" '
        # The value up to its first unquoted `#`, honouring dotenv_render_value backslash escapes
        # inside double quotes. Sets CUT when a comment was dropped and OPEN on an unclosed quote.
        function cut_comment(v,   i, c, q) {
            q = ""; CUT = 0
            for (i = 1; i <= length(v); i++) {
                c = substr(v, i, 1)
                if (q == "\"" && c == "\\") { i++; continue }
                if (q != "") { if (c == q) q = ""; continue }
                if (c == "\"" || c == "\047") q = c
                else if (c == "#") { CUT = 1; break }
            }
            OPEN = (q != "")
            return substr(v, 1, i - 1)
        }
        BEGIN { n = split(survivors, list, " "); for (i = 1; i <= n; i++) ok[list[i]] = 1 }
        /^[ \t\r]*$/ { print; next }
        match($0, /^[ \t]*(#[# \t]*)?(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) {
            lhs = substr($0, 1, RLENGTH)
            key = lhs
            sub(/^[ \t]*(#[# \t]*)?(export[ \t]+)?/, "", key)
            sub(/[ \t]*=$/, "", key)
            if (!(key in ok)) { print lhs "[redacted]"; next }
            val = cut_comment(substr($0, RLENGTH + 1))
            if (OPEN || val ~ /=/) { print lhs "[redacted]"; next }
            if (CUT) { sub(/[ \t]+$/, "", val); print lhs val " # [redacted]" } else print lhs val
            next
        }
        /^[ \t]*#/ {
            line = $0; out = ""
            while (match(line, /[A-Za-z_][A-Za-z0-9_]*[ \t]*=/)) {
                s = RSTART + RLENGTH
                key = substr(line, RSTART, RLENGTH)
                sub(/[ \t]*=$/, "", key)
                match(substr(line, s), /^[^ \t]*/)
                if (!(key in ok) || substr(line, s, RLENGTH) ~ /=/) {
                    out = out substr(line, 1, s - 1) "[redacted]"; line = ""; break
                }
                out = out substr(line, 1, s - 1 + RLENGTH)
                line = substr(line, s + RLENGTH)
            }
            print out line
            next
        }
        { print "[redacted]" }
    '
}

bundle_redact_log() {
    sed -E -e "$BUNDLE_REDACT_SED"
}

bundle_support_journal_unreadable() {
    local out
    out=$(journalctl --system -n 1 --no-pager 2>&1 </dev/null) || {
        printf '%s' "$out" | tr '\n' ' ' | cut -c1-200
        return 0
    }
    case "$out" in
    *"insufficient permissions"* | *"Permission denied"* | *"not seeing messages from other users and the system"*)
        printf '%s' "$out" | tr '\n' ' ' | cut -c1-200
        return 0
        ;;
    esac
    return 1
}

bundle_support_diy_collect() {
    local tmp="$1" cap="$2" since="$3" until="$4" juntil="$5" engine rc=0 names name runner=()
    command -v timeout >/dev/null 2>&1 && runner=(timeout "${PITHEAD_SUPPORT_STEP_TIMEOUT:-300}")
    mkdir -p "$tmp/bundle/containers"
    doctor_json >"$tmp/doctor.raw.json" 2>"$tmp/doctor.raw.txt" || rc=$?
    bundle_redact_log <"$tmp/doctor.raw.json" >"$tmp/bundle/doctor.json"
    bundle_redact_log <"$tmp/doctor.raw.txt" >"$tmp/bundle/doctor.txt"
    rm -f "$tmp/doctor.raw.json" "$tmp/doctor.raw.txt"
    [ "$rc" -gt 0 ] && log "doctor reported failures — included in the bundle." >&2
    tor_diagnostics_snapshot >"$tmp/bundle/tor-diagnostics.json" 2>/dev/null || true
    if [ -f "$CONFIG_FILE" ]; then
        [ -f "$tmp/scratch/masked/config.json" ] || render_masked_config "$tmp/scratch" >/dev/null 2>&1 || true
        [ -f "$tmp/scratch/masked/config.json" ] &&
            bundle_mask_config <"$tmp/scratch/masked/config.json" >"$tmp/bundle/config.masked.json"
    fi
    if [ -f .env ]; then
        bundle_redact_env <.env >"$tmp/bundle/env.redacted" 2>/dev/null || true
    fi
    engine=$(container_engine)
    if command -v "$engine" >/dev/null 2>&1 &&
        names=$("${runner[@]}" "$engine" compose ps --all --format '{{.Name}}' 2>"$tmp/engine.err" </dev/null); then
        "${runner[@]}" "$engine" compose ps --all </dev/null 2>&1 | bundle_redact_log >"$tmp/bundle/compose-ps.txt" || true
        while read -r name; do
            [ -n "$name" ] || continue
            bundle_support_capture "$tmp" "containers/$name.log" "$cap" 1 0 "$since" "$until" \
                sh -c 'exec "$1" logs --timestamps --since "$2" --until "$3" "$4" 2>&1' sh "$engine" "$since" "$juntil" "$name" || true
        done <<<"$names"
    else
        echo "container engine not reachable — no container state collected" >"$tmp/bundle/compose-ps.txt"
        bundle_support_step_fail "$tmp" containers failed "container engine not reachable: $(head -n1 "$tmp/engine.err" 2>/dev/null || echo "$engine not found")"
    fi
}

stack_support_bundle() {
    local usage="Usage: pithead support-bundle [--hours N] [--since TIME] [--until TIME]" out outdir arch
    bundle_support_cli_window "$usage" "$@"
    outdir=$(mktemp -d)
    trap 'rm -rf "$outdir"; exit 130' INT TERM HUP
    log "Collecting diagnostics (read-only)..."
    # shellcheck disable=SC2086
    arch=$(bundle_support_collect "$outdir" $BUNDLE_WINDOW) || {
        rm -rf "$outdir"
        trap - INT TERM HUP
        return 1
    }
    out="$PWD/$(basename "$arch")"
    mv -f "$arch" "$out" || {
        rm -rf "$outdir"
        trap - INT TERM HUP
        return 1
    }
    rm -rf "$outdir"
    trap - INT TERM HUP
    log "Support bundle written: $out"
    log "Secrets are redacted at collection, but REVIEW the contents before sharing: unzip -l $(basename "$out")"
}
