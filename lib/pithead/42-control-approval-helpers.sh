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
