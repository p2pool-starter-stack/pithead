# `support-bundle` (#77 phase 1): most support is log collection — one command gathers what a
# report needs into a chmod-600 tarball the operator reviews before sharing. Read-only; nothing
# leaves the box. Secrets are redacted at the source: config via the control channel's masking
# (render_masked_config), .env by a survivor allowlist over the rendered population
# (bundle_redact_env, #1631), container logs by argv position — p2pool echoes its --rpc-login, both
# wallet addresses and the service onion on launch, the leak class this exists to stop. The
# membership of that class was drawn too narrowly until #1585; add to bundle_redact_log, not to a
# second list.

# The `.env` allowlist, ruled on #1630/#1631: a denylist over a population someone else keeps
# extending fails silently and in the unsafe direction (it did, four times — #1596, #1609, #1611,
# #1621). An allowlist inverts the failure mode — a key absent from PITHEAD_ENV_SURVIVOR_KEYS is
# REDACTED, never printed, so a `render_env` addition nobody classified is safe by construction.
# Measured against the full 127-key rendered population (33-render-env.sh) at the time of this
# change; tests/integration/selftest/selftest-bundle-redact-env.sh re-derives that population and
# fails BY NAME on any key this list and its own classification disagree on.
PITHEAD_ENV_SURVIVOR_KEYS="CADDY_LOG_DIR CLEARNET_STATE_DIR COMPOSE_PROFILES CONTROL_DIR
DASHBOARD_CHECK_UPDATES DASHBOARD_CONTROL_ENABLED DASHBOARD_DATA_DIR DASHBOARD_EXPOSE_PUBLIC_IP
DASHBOARD_FAIL_CLOSED DASHBOARD_ONION_CLIENT_AUTH DASHBOARD_ONION_ENABLED DASHBOARD_SECURE
DASHBOARD_TZ DEPLOYMENT_COMPLETED HASHRATE_DROP_MINUTES HASHRATE_DROP_THRESHOLD_PCT HOST_PORT
MONERO_CLEARNET_SYNC MONERO_DATA_DIR MONERO_MEM_LIMIT MONERO_OUT_PEERS MONERO_PREP_THREADS
MONERO_PRUNE MONERO_RPC_BIND MONERO_RPC_PORT MONERO_WALLET_RPC_URL MONERO_ZMQ_BIND MONERO_ZMQ_PORT
NETWORK_PREFIX NETWORK_SUBNET NOTIFY_TOR P2POOL_CLEARNET P2POOL_DATA_DIR P2POOL_FLAGS P2POOL_PORT
P2POOL_URL PAYOUT_CONFIRM_ENABLED PAYOUT_SCAN_HEIGHT PITHEAD_TLS_DIR PROXY_API_PORT
PROXY_DONATE_LEVEL PROXY_STRATUM_TLS PROXY_TLS_DIR STRATUM_BIND STRATUM_PORT TARI_CLEARNET_SYNC
TARI_DATA_DIR TARI_GRPC_BIND TARI_MEM_LIMIT TARI_MODE TARI_PAYOUT_CONFIRM_ENABLED TARI_REQUIRED
TARI_WALLET_BIRTHDAY TARI_WALLET_GRPC_ADDRESS TARI_WALLET_SECRET_FILE TELEGRAM_COMMANDS_ENABLED
TELEGRAM_DAILY_SUMMARY_TIME TELEGRAM_ENABLED TELEGRAM_EVENT_BLOCK_FOUND
TELEGRAM_EVENT_CLEARNET_EXPOSED TELEGRAM_EVENT_CONTAINER_UNHEALTHY TELEGRAM_EVENT_DAILY_SUMMARY
TELEGRAM_EVENT_DB_RESET TELEGRAM_EVENT_DB_UNHEALTHY TELEGRAM_EVENT_DISK_SPACE
TELEGRAM_EVENT_HASHRATE_LOSS TELEGRAM_EVENT_HASHRATE_LOW TELEGRAM_EVENT_HIGH_REJECT_RATE
TELEGRAM_EVENT_HUGEPAGES TELEGRAM_EVENT_LOW_RAM TELEGRAM_EVENT_NEW_RELEASE
TELEGRAM_EVENT_NODE_DOWN TELEGRAM_EVENT_NODE_RECOVERED TELEGRAM_EVENT_PAYOUT_CONFIRMED
TELEGRAM_EVENT_PAYOUT_FOUND TELEGRAM_EVENT_RAFFLE_WIN TELEGRAM_EVENT_STACK_ONLINE
TELEGRAM_EVENT_SYNC_FINISHED TELEGRAM_EVENT_WALLET_CHANGED TELEGRAM_EVENT_WORKER_JOINED
TELEGRAM_EVENT_WORKER_LEFT TELEGRAM_EVENT_WORKER_OFFLINE TELEGRAM_EVENT_WORKER_RECOVERED
TELEGRAM_EVENT_XVB_NO_SHARE TELEGRAM_EVENT_XVB_REGISTRATION TOR_AUTO_HEAL TOR_DATA_DIR
TOR_EGRESS_FIREWALL WALLET_RPC_USERNAME XMRIG_API_AUTH XMRIG_API_PORT XVB_DONATION_LEVEL
XVB_ENABLED XVB_POOL_URL XVB_TOR_ENABLED"

# Everything not in PITHEAD_ENV_SURVIVOR_KEYS is redacted — credentials, wallet and view keys,
# onion identity, capability URLs and the handful of addressing fields the ruling classified as
# topology rather than structure (MONERO_NODE_HOST, TARI_GRPC_ADDRESS, HOST_IP).
#
# The allowlist also governs which LINES are read (#2414), and every ambiguity fails closed. A
# hand-edited .env keeps the previous value commented out above the live one, so an assignment
# behind `#`, indentation, `export` or spaces around `=` is classified like a live one: the prefix
# and key stay, the value goes. A survivor keeps its value up to the first unquoted `#`, which
# becomes `# [redacted]`; a survivor value that opens a quote it never closes, or carries a second
# `KEY=`, is redacted. A comment that is not an assignment keeps its prose, but every non-survivor
# `KEY=` inside it loses the rest of the line. Any other line is redacted whole, since it cannot
# be classified. Plain `[ \t]` rather than `[[:space:]]`: older mawk has no POSIX classes.
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
            if (OPEN || val ~ /(^|[ \t;])[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) { print lhs "[redacted]"; next }
            if (CUT) { sub(/[ \t]+$/, "", val); print lhs val " # [redacted]" } else print lhs val
            next
        }
        /^[ \t]*#/ {
            line = $0; out = ""
            while (match(line, /[A-Za-z_][A-Za-z0-9_]*[ \t]*=/)) {
                s = RSTART + RLENGTH
                key = substr(line, RSTART, RLENGTH)
                sub(/[ \t]*=$/, "", key)
                if (!(key in ok)) { out = out substr(line, 1, s - 1) "[redacted]"; line = ""; break }
                match(substr(line, s), /^[^ \t]*/)
                out = out substr(line, 1, s - 1 + RLENGTH)
                line = substr(line, s + RLENGTH)
            }
            print out line
            next
        }
        { print "[redacted]" }
    '
}

# Keyed by POSITION and not by shape, which is #1585's ruling: no length bar reaches all three Tari
# address forms this repo validates (91, 48 and 67 characters, the last non-alphanumeric), and a bar
# low enough to try starts eating ordinary log tokens. The onion keeps its own shape rule — it is
# the one value that also appears away from the launch line. The .env half of this bundle has always
# treated wallets and onions as secrets, so leaving them here shipped one artifact under two
# policies. Per-form rows and the full derivation: tests/integration/selftest/selftest-bundle-redact-log.sh;
# tests/integration/lib.sh's redact() keys on the same property (#1607) and the two stay in step.
#
# THE MONERO ADDRESS IS THE ONE VALUE THAT ALSO NEEDS A SHAPE RULE (#1750). Position is enough for
# an artifact the operator reviews before sharing; #1736 gave this same and only redactor a second
# consumer — `diag-logs` and `diag-doctor` stream its output to a browser over the network — and
# p2pool writes the payout wallet in ORDINARY BODY TEXT as well as on its launch line ("Your wallet
# <ADDR> got a payout of ..."), where there is no argv position to key on.
#
# This does NOT reopen #1585. That ruling is about a GENERAL address rule, and it stands: Tari has
# three forms at 91, 48 and 67 characters, one of them non-alphanumeric, so no bar reaches them all.
# Monero is the case it leaves open, because the Monero form is EXACT rather than approximate —
# prefix `4` or `8`, length 95 or 106, over the 58-character base58 alphabet that excludes 0 O I l.
# That is the same shape gate monero_address_type applies before it decodes (25-address-types.sh),
# and the two are held in step by the "classifier agrees" rows in the self-test, which drive both
# off the same real addresses. A TARI address in body text still survives; that gap is stated, not
# closed.
#
# WHY THE RULE IS APPLIED TWICE. POSIX ERE has no lookaround and BSD sed — a supported host, see
# safe_sed — has no \b, so the boundary characters either side have to be MATCHED, and matching
# them consumes them. Two addresses one space apart therefore need two passes: the first eats the
# space that is the second address's left boundary. Two is sufficient for any count, because after
# one pass every survivor is preceded by the replacement text. The self-test's adjacency row is the
# control: drop either -e and it reds alone.
bundle_redact_log() {
    # The Monero base58 alphabet — 58 characters, i.e. NOT 0, O, I or l.
    local b58='[1-9A-HJ-NP-Za-km-z]'
    local xmr_shape
    xmr_shape="s/(^|[^0-9A-Za-z])([48]${b58}{94}(${b58}{11})?)([^0-9A-Za-z]|\$)/\1[redacted-address]\4/g"
    sed -E \
        -e 's/(--rpc-login|--http-access-token|--tls-fingerprint)[= ][^ ]+/\1 [redacted]/g' \
        -e 's/(--wallet[ =])[^-[:space:]][^[:space:]]*/\1[redacted-address]/g' \
        -e 's/(--merge-mine[ =][^[:space:]]+[[:space:]]+)[^-[:space:]][^[:space:]]*/\1[redacted-address]/g' \
        -e 's/[a-z2-7]{56}\.onion/[redacted].onion/g' \
        -e "$xmr_shape" \
        -e "$xmr_shape"
}

stack_support_bundle() {
    _reject_options support-bundle "$@"
    local ts out tmp rc=0
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    out="$PWD/support-bundle-$ts.tar.gz"
    tmp=$(mktemp -d)
    mkdir -p "$tmp/bundle/logs"

    log "Collecting diagnostics (read-only)..."
    {
        echo "pithead ${PITHEAD_VERSION:-unknown}"
        uname -a
        echo
        df -h 2>/dev/null || true
        echo
        free -h 2>/dev/null || true
    } >"$tmp/bundle/host.txt" 2>&1
    doctor_json >"$tmp/bundle/doctor.json" 2>"$tmp/bundle/doctor.txt" || rc=$?
    [ "$rc" -gt 0 ] && log "doctor reported failures — included in the bundle."

    # Masked config: the same jq walk the dashboard prefill uses; every set secret leaf becomes
    # {"__secret__": true}. Rendered into the scratch dir, never into the live control spool.
    if [ -f "$CONFIG_FILE" ]; then
        render_masked_config "$tmp/scratch" 2>/dev/null || true
        [ -f "$tmp/scratch/masked/config.json" ] &&
            cp "$tmp/scratch/masked/config.json" "$tmp/bundle/config.masked.json"
    fi
    # .env with secret-bearing values stripped by the survivor allowlist above; structure (ports,
    # dirs, modes) stays — that is what support actually needs.
    if [ -f .env ]; then
        bundle_redact_env <.env >"$tmp/bundle/env.redacted" 2>/dev/null || true
    fi

    # Container state + recent logs, when an engine is reachable. bundle_redact_log guards the
    # launch lines services echo — the credential flags, the wallet addresses and the service
    # onion — plus any Monero address and any onion in body text (#1750).
    if docker compose ps >"$tmp/bundle/compose-ps.txt" 2>/dev/null; then
        local svc
        for svc in $(docker compose ps --all --format '{{.Service}}' 2>/dev/null); do
            docker compose logs --no-color --tail 200 "$svc" 2>/dev/null |
                bundle_redact_log >"$tmp/bundle/logs/$svc.log" || true
        done
    else
        echo "container engine not reachable — no container state collected" >"$tmp/bundle/compose-ps.txt"
    fi

    tar -czf "$out" -C "$tmp" bundle
    chmod 600 "$out"
    rm -rf "$tmp"
    log "Support bundle written: $out"
    log "Secrets are redacted at collection, but REVIEW the contents before sharing: tar -tzf $(basename "$out")"
}
