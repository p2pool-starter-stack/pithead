ensure_config_exists() {
    [ -f "$CONFIG_FILE" ] && return 0

    if [ ! -t 0 ]; then
        error "$CONFIG_FILE not found and no interactive terminal is available.\n  Create it first (copy config.minimal.json to config.json and edit it), then re-run."
    fi

    log "$CONFIG_FILE not found. Starting interactive setup..."
    jq -e . "$CORE_KEYS_CONFIG" >/dev/null 2>&1 ||
        error "$CORE_KEYS_CONFIG is missing or not valid JSON (the wizard's core-key shortlist). Reinstall or redownload the release bundle."
    echo "Please provide the following details to generate a minimal configuration:"

    wizard_ask_core
    wizard_ask_profile
    wizard_write_config
    chmod 600 "$CONFIG_FILE"
    log "$CONFIG_FILE created successfully."
}

wizard_ask_core() {
    while :; do
        read -r -p "Enter Monero Wallet Address (primary — starts with 4): " IN_MONERO_WALLET || error "End of input while reading the Monero payout address. Aborting."
        case "$(monero_address_type "$IN_MONERO_WALLET")" in
        primary) break ;;
        subaddress) echo "  ✗ That's a subaddress (8…) — p2pool can't pay it. Use your PRIMARY address (starts with 4)." >&2 ;;
        integrated) echo "  ✗ That's an integrated address — use your plain primary address." >&2 ;;
        checksum) echo "  ✗ Checksum failed — at least one character is mistyped. Re-copy the address from your wallet." >&2 ;;
        *) echo "  ✗ Not a valid Monero primary address (95 chars, starts with 4). Try again." >&2 ;;
        esac
    done
    [ -n "$IN_MONERO_WALLET" ] || error "A Monero wallet address is required. Aborting."

    MONERO_MODE_WIZ="local"
    IN_MONERO_USER=$(default_node_username)
    IN_MONERO_PASS=$(generate_node_password)
    log "Using the bundled Monero node; its internal RPC credentials were generated and saved in $CONFIG_FILE."

    wizard_ask_tari

    IN_DASH_USER="admin"
    IN_DASH_PASS=$(generate_node_password) || error "Could not generate a dashboard password. Setup aborted."
    [[ "$IN_DASH_PASS" =~ ^[A-Za-z0-9]{32}$ ]] || error "Could not generate a dashboard password. Setup aborted."
}

wizard_ask_tari() {
    IN_TARI_WALLET="" TARI_MODE_WIZ="off"
    echo ""
    echo "Tari merge-mining is optional and a beta: it earns Tari from the same work that mines Monero, but the bundled node syncs a Tari chain over Tor, which takes days."
    while :; do
        read -r -p "Enter Tari Wallet Address (Enter to skip and mine Monero only): " IN_TARI_WALLET || error "End of input while reading the Tari payout address. Aborting."
        [ -z "$IN_TARI_WALLET" ] && break
        case "$(tari_address_type "$IN_TARI_WALLET")" in
        ok | unchecked) break ;;
        checksum) echo "  ✗ Checksum failed — at least one character is mistyped. Re-copy the address from your Tari wallet." >&2 ;;
        network) echo "  ✗ That address is for a Tari testnet — this stack mines MAINNET Tari. Use your mainnet address." >&2 ;;
        *) echo "  ✗ Not a valid Tari address (base58 or emoji form). Try again." >&2 ;;
        esac
    done
    if [ -z "$IN_TARI_WALLET" ]; then
        log "Tari merge-mining is OFF. Turn it on later by setting tari.mode and tari.wallet_address in $CONFIG_FILE and running '$0 apply'."
        return 0
    fi
    TARI_MODE_WIZ="local"
    log "Tari merge-mining is ON, with the bundled Tari node."
}

wizard_ask_profile() {
    echo ""
    echo "--- Profile ---"
    echo "  1) Performance — fastest sync and best yield. Nothing leaves through Tor, so fast sync shows your IP address to the Monero and Tari networks."
    echo "  2) Balance — everything leaves through Tor. This is the default."
    echo "  3) Privacy — Balance, plus P2Pool peers only over onion connections and a generated rig password and worker token."
    read -r -p "Profile [2]: " IN_PROFILE || true
    case "$(printf '%s' "$IN_PROFILE" | tr 'A-Z' 'a-z')" in
    1 | performance) WIZ_PROFILE=performance ;;
    "" | 2 | balance) WIZ_PROFILE=balance ;;
    3 | privacy) WIZ_PROFILE=privacy ;;
    *)
        echo "  Not 1/2/3 — taking Balance." >&2
        WIZ_PROFILE=balance
        ;;
    esac
    if [ "$WIZ_PROFILE" = performance ]; then
        warn "Performance syncs the Monero and Tari chains over clearnet: your IP address is visible to those networks until the initial sync finishes."
    fi
}

wizard_write_config() {
    local cfg
    cfg=$(jq -n \
        --argjson defaults "$(new_install_defaults)" \
        --arg mode "$MONERO_MODE_WIZ" \
        --arg mwallet "$IN_MONERO_WALLET" \
        --arg mu "$IN_MONERO_USER" \
        --arg mp "$IN_MONERO_PASS" \
        --arg tmode "$TARI_MODE_WIZ" \
        '$defaults * {monero: {mode: $mode, wallet_address: $mwallet, node_username: $mu, node_password: $mp},
          tari: {mode: $tmode},
          dashboard: {secure: true}}')

    if [ "$TARI_MODE_WIZ" != "off" ]; then
        cfg=$(jq --arg tw "$IN_TARI_WALLET" '.tari.wallet_address = $tw' <<<"$cfg")
    fi

    if [ -n "$IN_DASH_PASS" ]; then
        cfg=$(jq --arg u "$IN_DASH_USER" --arg p "$IN_DASH_PASS" '.dashboard.auth = {username: $u, password: $p}' <<<"$cfg")
    fi

    (
        umask 077
        printf '%s\n' "$cfg" >"$CONFIG_FILE"
        profile_select "$CONFIG_FILE" "${WIZ_PROFILE:-balance}"
    )
}

wizard_print_pointer() {
    echo ""
    if [ -n "${IN_DASH_PASS:-}" ]; then
        echo "Dashboard login: $IN_DASH_USER"
        echo "Generated dashboard password: $IN_DASH_PASS"
        echo "Save it now — it is also stored in your owner-only config.json."
    fi
    echo "That's the core config — everything else (ports, XvB, alerts, energy pricing, per-worker"
    echo "overrides, ...) keeps its default. A remote Monero or Tari node, dashboard onion access,"
    echo "Telegram alerts, a local miner and a stratum password are set later in $CONFIG_FILE or the"
    echo "dashboard's Settings. Want on-chain payout confirmation, a per-kWh cost, or"
    echo "per-worker overrides? Set monero.view_key / dashboard.energy.cost_per_kwh / workers.list in"
    echo "$CONFIG_FILE and run '$0 apply' — see $DOCS_URL/docs/configuration.md, or use the dashboard's config editor."
}
