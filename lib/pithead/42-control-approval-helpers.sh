# Shared helpers for the control approval envelope and audit provenance (#1959/#1962).
control_changed_config_paths() { # <staged-file>
    jq -rn --slurpfile ref "$REFERENCE_CONFIG" --slurpfile live "$CONFIG_FILE" --slurpfile staged "$1" '
        def merged($x): $ref[0] * $x;
        # Scalar arrays are one configuration setting. Collapse their numeric indexes so audit
        # reconciliation uses the same dotted path as the dashboard config flattener.
        def leaves($x): [$x | paths(scalars)
            | select(.[0:2] != ["workers", "list"])
            | map(select(type == "string"))];
        (leaves(merged($live[0])) + leaves(merged($staged[0])) | unique)[] as $p
        | select((merged($live[0]) | getpath($p)) != (merged($staged[0]) | getpath($p)))
        | $p | map(tostring) | join(".")' 2>/dev/null
}

control_never_path_changed() { # <staged-file>
    local changed never
    while IFS= read -r changed; do
        [ -n "$changed" ] || continue
        for never in $CONTROL_DASHBOARD_NEVER_PATHS; do
            case "$changed" in "$never" | "$never".*) return 0 ;; esac
        done
    done < <(control_changed_config_paths "$1")
    return 1
}

# Return the first masked capability whose destination changed in a preview request. A sentinel may
# preserve an existing secret, but it must never let the browser redirect that secret somewhere new.
control_masked_binding_error() { # <request-file>
    jq -r --slurpfile live "$CONFIG_FILE" --slurpfile ref "$REFERENCE_CONFIG" '
        def sentinel: type == "object" and .__secret__ == true;
        def full($cfg): $ref[0] * $cfg;
        def global_worker_context($cfg):
          (full($cfg) | .workers // {}) as $w
          | if ($w.api_auth // "none") != "token" then []
            else [["fleet", ($w.api_port // 8080)]]
              + [($w.list // [])[]?
                 | select((.token // "") == "")
                 | ["worker", (.name // ""), (.host // ""), (.port // ($w.api_port // 8080))]]
            end;
        def monero_rpc_endpoint($cfg):
          full($cfg) | [(.monero.mode // "local"), (.monero.remote.host // ""),
                        (.monero.remote.rpc_port // 18081)];
        .config as $candidate
        | [
            if (($candidate.workers.api_token | sentinel)
                and (((global_worker_context($candidate) - global_worker_context($live[0])) | length) > 0))
            then "workers.api_token is masked while a new worker endpoint would receive it — enter the shared token explicitly"
            else empty end,
            if ((($candidate.notifications.ntfy.token | sentinel)
                 and (($candidate.notifications.ntfy.url | sentinel) | not)
                 and ((full($candidate).notifications.ntfy.url // "") != "")
                 and ((full($candidate).notifications.ntfy.url // "")
                      != (full($live[0]).notifications.ntfy.url // ""))))
            then "notifications.ntfy.url changed while its token was masked — enter the token for the new URL explicitly"
            else empty end,
            if (((($candidate.monero.node_username | sentinel)
                  or ($candidate.monero.node_password | sentinel))
                 and ((full($candidate).monero.mode // "local") == "remote")
                 and (monero_rpc_endpoint($candidate) != monero_rpc_endpoint($live[0]))))
            then "the Monero RPC endpoint changed while its credentials were masked — enter the credentials for the new endpoint explicitly"
            else empty end
          ] | .[0] // empty' "$1" 2>/dev/null
}

# Add synthetic rows for confirmed source paths that are inert in the current mode and therefore
# absent from apply's env-var porcelain.
control_mark_config_confirm_rows() { # <newline paths> <porcelain>
    local paths="$1" out="$2" path endpoint_key
    out=$(printf '%s\n' "$out" | awk -F'\t' 'BEGIN {OFS=FS} $2 == "P2POOL_FLAGS" {$1="CONFIRM"} {print}')
    while IFS= read -r path; do
        case "$path" in
        monero.remote.host) endpoint_key=MONERO_NODE_HOST ;;
        monero.remote.rpc_port) endpoint_key=MONERO_RPC_PORT ;;
        monero.remote.zmq_port) endpoint_key=MONERO_ZMQ_PORT ;;
        tari.remote.host | tari.remote.grpc_port) endpoint_key=TARI_GRPC_ADDRESS ;;
        *) continue ;;
        esac
        printf '%s\n' "$out" | awk -F'\t' -v k="$endpoint_key" '$2 == k {found=1} END {exit !found}' && continue
        out+="${out:+$'\n'}CONFIRM"$'\t'"$path"$'\tRemote node endpoint settings are changing.'
    done <<<"$paths"
    printf '%s' "$out"
}

_control_paths_overlap() { # <normalized-a> <normalized-b>
    case "${1%/}/" in "${2%/}"/*) return 0 ;; esac
    case "${2%/}/" in "${1%/}"/*) return 0 ;; esac
    return 1
}

# Resolve all five staged data destinations exactly as apply does, then keep every mount disjoint
# from its peers and from state the dashboard can already write. Checking lexical and canonical
# spellings closes both direct ancestor mounts and symlink aliases.
control_validate_data_dir_overlaps() { # <staged-file>
    local staged="$1" data_root path lex real i j current_dashboard control_dir clearnet_dir
    local monero_current tari_current p2pool_current tor_current caddy_dir proxy_tls_dir
    local -a names=(monero.data_dir tari.data_dir p2pool.data_dir tor.data_dir dashboard.data_dir)
    local -a paths lexes=() reals=() protected_names protected_paths protected_lexes=() protected_reals=()
    paths=(
        "$(resolve_default "$(jq -r '.monero.data_dir // empty' "$staged")" "$PWD/data/monero")"
        "$(resolve_default "$(jq -r '.tari.data_dir // empty' "$staged")" "$PWD/data/tari")"
        "$(resolve_default "$(jq -r '.p2pool.data_dir // empty' "$staged")" "$PWD/data/p2pool")"
        "$(resolve_default "$(jq -r '.tor.data_dir // empty' "$staged")" "$PWD/data/tor")"
    )
    data_root=$(dirname "${paths[0]}")
    [ "$(dirname "${paths[1]}")" = "$data_root" ] &&
        [ "$(dirname "${paths[2]}")" = "$data_root" ] &&
        [ "$(dirname "${paths[3]}")" = "$data_root" ] || data_root="$PWD/data"
    paths+=("$(resolve_default "$(jq -r '.dashboard.data_dir // empty' "$staged")" "$data_root/dashboard")")
    for path in "${paths[@]}"; do
        lex=$(realpath -ms -- "$path" 2>/dev/null) || lex=""
        real=$(realpath -m -- "$path" 2>/dev/null) || real=""
        [ -n "$lex" ] && [ -n "$real" ] || {
            printf 'a staged data directory cannot be resolved safely. %s' "$(_control_host_remedy)"
            return 1
        }
        lexes+=("$lex")
        reals+=("$real")
    done
    for ((i = 0; i < ${#paths[@]}; i++)); do
        for ((j = i + 1; j < ${#paths[@]}; j++)); do
            if _control_paths_overlap "${lexes[i]}" "${lexes[j]}" ||
                _control_paths_overlap "${reals[i]}" "${reals[j]}"; then
                printf 'this move makes %s overlap %s — data destinations must be separate siblings. %s' \
                    "${names[i]}" "${names[j]}" "$(_control_host_remedy)"
                return 1
            fi
        done
    done

    monero_current=$(env_get MONERO_DATA_DIR)
    tari_current=$(env_get TARI_DATA_DIR)
    p2pool_current=$(env_get P2POOL_DATA_DIR)
    tor_current=$(env_get TOR_DATA_DIR)
    current_dashboard=$(env_get DASHBOARD_DATA_DIR)
    control_dir=$(env_get CONTROL_DIR)
    clearnet_dir=$(env_get CLEARNET_STATE_DIR)
    caddy_dir=$(env_get CADDY_LOG_DIR)
    proxy_tls_dir=$(env_get PROXY_TLS_DIR)
    [ -n "$monero_current" ] || monero_current="$PWD/data/monero"
    [ -n "$tari_current" ] || tari_current="$PWD/data/tari"
    [ -n "$p2pool_current" ] || p2pool_current="$PWD/data/p2pool"
    [ -n "$tor_current" ] || tor_current="$PWD/data/tor"
    [ -n "$current_dashboard" ] || current_dashboard="$PWD/data/dashboard"
    [ -n "$control_dir" ] || control_dir="$PWD/data/control"
    [ -n "$clearnet_dir" ] || clearnet_dir="$PWD/data/clearnet-state"
    [ -n "$caddy_dir" ] || caddy_dir="$PWD/data/caddy-logs"
    [ -n "$proxy_tls_dir" ] || proxy_tls_dir="$PWD/data/proxy-tls"
    protected_names=(live.monero live.tari live.p2pool live.tor live.dashboard control.state clearnet.state caddy.logs live.proxy-tls staged.proxy-tls)
    protected_paths=("$monero_current" "$tari_current" "$p2pool_current" "$tor_current" "$current_dashboard"
        "$control_dir" "$clearnet_dir" "$caddy_dir" "$proxy_tls_dir" "$data_root/proxy-tls")
    for path in "${protected_paths[@]}"; do
        lex=$(realpath -ms -- "$path" 2>/dev/null) || lex=""
        real=$(realpath -m -- "$path" 2>/dev/null) || real=""
        protected_lexes+=("$lex")
        protected_reals+=("$real")
    done
    for ((i = 0; i < ${#paths[@]}; i++)); do
        for ((j = 0; j < ${#protected_paths[@]}; j++)); do
            [ -n "${protected_lexes[j]}" ] && [ -n "${protected_reals[j]}" ] || continue
            # Keeping any service at its own current mount is intentional; every cross-over is not.
            if [ "$i" -eq "$j" ] && [ "$j" -lt 5 ] &&
                [ "${lexes[i]}" = "${protected_lexes[j]}" ] &&
                [ "${reals[i]}" = "${protected_reals[j]}" ]; then
                continue
            fi
            if _control_paths_overlap "${lexes[i]}" "${protected_lexes[j]}" ||
                _control_paths_overlap "${reals[i]}" "${protected_reals[j]}"; then
                printf 'this move makes %s overlap internal or dashboard-writable %s. %s' \
                    "${names[i]}" "${protected_names[j]}" "$(_control_host_remedy)"
                return 1
            fi
        done
    done
}

# Typed payout confirmation for a sensitive dashboard commit (#2076). The dashboard collects the
# last characters of a new payout address and the host re-checks them against the STAGED file, so a
# fat-fingered or truncated paste cannot reach an unrecoverable field. This is typo protection, not
# a second identity: #338's Telegram approval tap was removed, and a compromised dashboard that can
# set the address can also supply its own suffix.
control_validate_approval() { # <staged-file> <actor> <approval-json> <porcelain>
    local staged="$1" actor="$2" approval="$3" porcelain="$4"
    local chain env_key expected supplied suffixes
    [ -n "$actor" ] || {
        printf 'sign in before approving this sensitive change'
        return 1
    }
    jq -e '
        type == "object" and ((.payout_suffixes // {}) | type == "object")
        and ([keys[] | select(. != "payout_suffixes")] | length == 0)
        and ([.payout_suffixes | keys[] | select(. != "monero" and . != "tari")] | length == 0)
        and ([.payout_suffixes[] | select(type != "string")] | length == 0)
    ' <<<"$approval" >/dev/null 2>&1 || {
        printf 'sensitive changes need typed payout confirmations'
        return 1
    }
    suffixes=$(jq -c '.payout_suffixes // {}' <<<"$approval")
    for chain in monero tari; do
        env_key="$(printf '%s' "$chain" | tr 'a-z' 'A-Z')_WALLET_ADDRESS"
        if printf '%s' "$porcelain" | awk -F'\t' -v k="$env_key" '$2 == k {found=1} END {exit !found}'; then
            expected=$(jq -r --arg c "$chain" '.[$c].wallet_address // "" | if length > 8 then .[-8:] else . end' "$staged")
            supplied=$(jq -r --arg c "$chain" '.[$c] // ""' <<<"$suffixes")
            [ -n "$expected" ] && [ "$supplied" = "$expected" ] || {
                printf 'type the final characters of the new %s payout address exactly' "$chain"
                return 1
            }
        fi
    done
}

# Called only by an explicit successful firstboot boundary; absence of a snapshot is not provenance.
control_audit_provisioned() { # [control-dir]
    local cdir="${1:-$(env_get CONTROL_DIR)}" id
    [ -n "$cdir" ] || cdir="$PWD/data/control"
    mkdir -p "$cdir/audit"
    id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
    printf '%s' "$id" | grep -qE '^[0-9a-f-]{36}$' || return 1
    control_audit "$cdir/audit/control.log" "$id" "setup-wizard" "provision" "applied" ""
}

control_consume_provisioning_marker() { # <marker>
    [ -f "$1" ] || return 0
    control_audit_provisioned "$PWD/data/control" || return 1
    rm -f "$1"
}

porcelain_keys() {
    printf '%s' "$1" | awk -F'\t' 'NF' | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//'
}

control_write_result() { # <results-dir> <id> <json>
    printf '%s\n' "$3" >"$1/.$2.tmp" && mv "$1/.$2.tmp" "$1/$2.json"
}

# Values never enter the audit log: keys are the path names re-derived from live and staged files.
control_audit() { # <audit-file> <id> <actor> <action> <status> [keys] [approver]
    if [ -f "$1" ] && [ "$(wc -c <"$1" | tr -d ' ')" -gt 524288 ]; then
        tail -n 2000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"
    fi
    printf '{"ts":"%s","id":"%s","actor":"%s","action":"%s","status":"%s","keys":"%s","approver":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(printf '%s' "$2" | tr -cd 'A-Za-z0-9-')" \
        "$(printf '%s' "$3" | tr -cd 'A-Za-z0-9._@-')" \
        "$(printf '%s' "$4" | tr -cd 'a-z-')" \
        "$(printf '%s' "$5" | tr -cd 'a-z-')" \
        "$(printf '%s' "${6:-}" | tr -cd 'A-Za-z0-9._ ')" \
        "$(printf '%s' "${7:-}" | tr -cd 'A-Za-z0-9._@-')" >>"$1"
}
