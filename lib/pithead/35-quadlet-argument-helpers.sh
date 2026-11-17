# Quote one operator-supplied systemd Exec= argument; backslash, quote, dollar and percent are
# unit-file syntax, and the caller needs one argument after systemd expands the line.
quadlet_quote_exec_arg() {
    local v="${1//\\/\\\\}"
    v=${v//\"/\\\"}
    v=${v//%/%%}
    v=${v//\$/\$\$}
    printf '"%s"' "$v"
}

quadlet_wallet_deps() {
    case ",$1," in
    *,local_node,*) printf 'After=monerod.service\nRequires=monerod.service' ;;
    esac
}

quadlet_wallet_node() {
    case ",$1," in
    *,local_node,*) printf 'MONERO_NODE_HOST=%s.26 MONERO_RPC_PORT=18081' "$2" ;;
    *) printf '%s %s PAYOUT_NODE_REMOTE=true %s' "$(_qenvq MONERO_NODE_HOST)" "$(_qenvq MONERO_RPC_PORT)" "$(_qenvq PAYOUT_NODE_PROXY)" ;;
    esac
}
