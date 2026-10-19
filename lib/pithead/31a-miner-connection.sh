# shellcheck shell=bash
# Shared public certificate digest for the hand-off and dashboard connection block.
stratum_tls_fingerprint() {
    [ "${STRATUM_TLS:-false}" = true ] && [ -f "${PROXY_TLS_DIR:-}/cert.pem" ] || return 0
    openssl x509 -in "$PROXY_TLS_DIR/cert.pem" -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Resolving auto once and retaining its seed keeps the card and eventual daemon in agreement.
# The installer stores this in the existing root-only volatile carry, never on the ESP.
wizard_prepare_miner_connection() ( # <candidate> <installer> [spool] -> connection JSON
    local candidate="$1" installer="$2" carry mode saved="" final_dir tmp target="" wipe="" snap fingerprint
    carry="$(restore_carry_dir)/connection"
    umask 077
    mkdir -p "$carry" || return 1
    chmod 700 "$carry" || return 1
    if [ -f "$candidate.stratum-password" ]; then
        saved=$(cat "$candidate.stratum-password")
        rm -f "$candidate.stratum-password" || return 1
    elif [ "$installer" = 0 ]; then
        saved=$(env_get PROXY_STRATUM_PASSWORD)
    fi
    mode=$(jq -r '.p2pool.stratum_password // ""' "$candidate") || return 1
    STRATUM_PASSWORD="$mode"
    if [ "$mode" = auto ]; then
        STRATUM_PASSWORD="$saved"
        [ -n "$STRATUM_PASSWORD" ] || STRATUM_PASSWORD=$(openssl rand -hex 12) || return 1
    fi
    STRATUM_TLS=$(jq -r '.p2pool.stratum_tls // false' "$candidate") || return 1
    # Resolve only the directories in a child so the candidate's parse cannot replace the
    # host loop's config globals. The normal validator has already accepted this candidate.
    final_dir=$(PITHEAD_CONFIG_FILE="$candidate" PITHEAD_CONFIG_SET=1 bash -c 'source "$1"; parse_and_validate_config >/dev/null; printf "%s" "$PROXY_TLS_DIR"' _ "${BASH_SOURCE[0]}") || return 1
    PROXY_TLS_DIR="$final_dir"
    if [ "$installer" = 1 ]; then
        case "$final_dir" in /data/*) ;; *) return 1 ;; esac
        PROXY_TLS_DIR="$carry/tls"
        if [ -n "${3:-}" ]; then
            snap=$(wizard_spool_request "$3" install-request) || return 1
            target=$(cut -f1 <"$snap" | tr -dc 'a-zA-Z0-9_-')
            wipe=$(cut -f2 <"$snap" | LC_ALL=C tr -dc '[:lower:]')
            wizard_spool_clean "${snap%/*}" || return 1
            "$(install_bin)" --list | cut -f1 | grep -qx "$target" || return 1
            if [ "$STRATUM_TLS" = true ] && [ "$wipe" = keep ]; then
                wizard_retain_target_tls "/dev/$target" "$final_dir" "$carry/tls" || return 1
            fi
        fi
    fi
    if [ "$STRATUM_TLS" = true ]; then
        mkdir -p "$PROXY_TLS_DIR" || return 1
        ensure_stratum_tls_cert >/dev/null || return 1
    fi
    fingerprint=$(stratum_tls_fingerprint) || return 1
    [ "$STRATUM_TLS" != true ] || [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1
    jq -n --arg password "$STRATUM_PASSWORD" --argjson tls "$STRATUM_TLS" \
        --arg fingerprint "$fingerprint" --arg tls_dir "$final_dir" --arg target "$target" --arg wipe "$wipe" \
        '{stratum_password:$password,stratum_tls:$tls,stratum_fingerprint:$fingerprint,tls_dir:$tls_dir,target:$target,wipe:$wipe}' >"$carry/state.json" || return 1
    if [ "$installer" = 0 ] && [ "$mode" = auto ]; then
        tmp=$(mktemp "${ENV_FILE}.XXXXXX") || return 1
        if [ -f "$ENV_FILE" ]; then
            awk '!/^PROXY_STRATUM_PASSWORD=/' "$ENV_FILE" >"$tmp" || return 1
        fi
        printf 'PROXY_STRATUM_PASSWORD=%s\n' "$STRATUM_PASSWORD" >>"$tmp" && mv "$tmp" "$ENV_FILE" || return 1
    fi
    jq 'del(.tls_dir,.target,.wipe)' "$carry/state.json"
)

# Copy the volatile identity directly to the installed data filesystem. Called after restore,
# so restored .env fields remain intact; the carried password is the one the card displayed.
install_miner_connection_to_target() ( # <disk>
    local carry part mnt dir rel parent env tmp mounted=0 rc=0
    carry="$(restore_carry_dir)/connection"
    [ -f "$carry/state.json" ] || return 0
    systemd-repart --dry-run=no "$1" >/dev/null 2>&1 || return 1
    udevadm settle --timeout=10 2>/dev/null || true
    part=$(lsblk -lnpo NAME,PARTLABEL "$1" | awk '$2 == "data" {print $1; exit}')
    [ -n "$part" ] || return 1
    mnt=$(mktemp -d) || return 1
    trap 'rc=$?; if [ "$mounted" = 1 ]; then umount "$mnt" || rc=1; fi; rmdir "$mnt" || rc=1; exit "$rc"' EXIT
    mount -t ext4 -o rw,nosuid,nodev,noexec "$part" "$mnt" || return 1
    mounted=1
    dir=$(jq -r '.tls_dir' "$carry/state.json")
    parent=$(miner_connection_target_path "$mnt" "$dir") || return 1
    rel="${parent#"$mnt"/}"
    [ ! -L "$mnt/pithead" ] && [ ! -L "$mnt/pithead/.env" ] || return 1
    [ ! -e "$mnt/pithead/.env" ] || [ -f "$mnt/pithead/.env" ] || return 1
    umask 077
    mkdir -p "$mnt/pithead" || return 1
    env="$mnt/pithead/.env"
    tmp=$(mktemp "$mnt/pithead/.env.XXXXXX") || return 1
    [ ! -f "$env" ] || awk '!/^PROXY_STRATUM_PASSWORD=/' "$env" >"$tmp" || return 1
    printf 'PROXY_STRATUM_PASSWORD=%s\n' "$(jq -r '.stratum_password' "$carry/state.json")" >>"$tmp" && mv "$tmp" "$env" || return 1
    if [ "$(jq -r '.stratum_tls' "$carry/state.json")" = true ]; then
        [ ! -L "$mnt/$rel/key.pem" ] && [ ! -L "$mnt/$rel/cert.pem" ] || return 1
        mkdir -p "$mnt/$rel" || return 1
        install -m 600 "$carry/tls/key.pem" "$mnt/$rel/key.pem" &&
            install -m 644 "$carry/tls/cert.pem" "$mnt/$rel/cert.pem" || return 1
        chown -R "$APP_UID:$APP_GID" "$mnt/$rel" || return 1
    fi
    sync || return 1
)

# A config-only restore does not need the rest of its derived state yet. Only the auto seed
# crosses into the hand-off, with the same hex/duplicate checks as the full restore gate.
restore_card_stratum_seed() { # <validated-config> <archive-env> <private-output>
    local mode value count
    mode=$(jq -r '.p2pool.stratum_password // ""' "$1") || return 1
    value="$mode"
    if [ "$mode" = auto ]; then
        count=0
        if [ -f "$2" ]; then
            count=$(awk '/^PROXY_STRATUM_PASSWORD=/{n++} END{print n+0}' "$2")
        fi
        [ "$count" -le 1 ] || return 1
        value=$(env_get_file "$2" PROXY_STRATUM_PASSWORD)
        [[ -z "$value" || "$value" =~ ^[0-9a-f]{24}$ ]] || return 1
        [ -n "$value" ] || value=$(openssl rand -hex 12) || return 1
    fi
    (umask 077 && printf '%s' "$value" >"$3")
}

# Validate components without newline-based path encoding; files are checked by each caller.
miner_connection_target_path() { # <mount> </data/path>
    local mnt="$1" dir="$2" rel parent component
    [[ "$dir" != *[[:cntrl:]]* ]] || return 1
    case "$dir" in /data/*) rel="${dir#/data/}" ;; *) return 1 ;; esac
    case "/$rel/" in */../* | */./* | *//*) return 1 ;; esac
    parent="$mnt"
    while IFS= read -r component || [ -n "$component" ]; do
        parent="$parent/$component"
        [ ! -L "$parent" ] || return 1
    done < <(printf '%s' "$rel" | tr '/' '\n')
    printf '%s' "$parent"
}

wizard_retain_target_tls() ( # <disk> <final-dir> <private-carry>
    local part mnt dir mounted=0 rc=0
    part=$(lsblk -lnpo NAME,PARTLABEL "$1" | awk '$2 == "data" {print $1; exit}')
    [ -n "$part" ] || return 0 # a blank target has no previous identity
    mnt=$(mktemp -d) || return 1
    trap 'rc=$?; if [ "$mounted" = 1 ]; then umount "$mnt" || rc=1; fi; rmdir "$mnt" || rc=1; exit "$rc"' EXIT
    mount -t ext4 -o ro,noload,nosuid,nodev,noexec "$part" "$mnt" || return 1
    mounted=1
    dir=$(miner_connection_target_path "$mnt" "$2") || return 1
    [ ! -L "$dir/cert.pem" ] && [ ! -L "$dir/key.pem" ] || return 1
    [ -e "$dir/cert.pem" ] || [ -e "$dir/key.pem" ] || return 0
    [ -f "$dir/cert.pem" ] && [ -f "$dir/key.pem" ] || return 1
    # A stale/mismatched pair must not advertise a pin that no daemon can serve.
    local cert_key private_key
    cert_key=$(openssl x509 -in "$dir/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) || return 1
    private_key=$(openssl pkey -in "$dir/key.pem" -pubout -outform DER | sha256sum) || return 1
    [ "$cert_key" = "$private_key" ] || return 1
    (umask 077 && mkdir -p "$3" && install -m 600 "$dir/cert.pem" "$3/cert.pem" && install -m 600 "$dir/key.pem" "$3/key.pem")
)

validate_miner_connection_install_request() { # <target-name> <wipe>
    local state target wipe
    state="$(restore_carry_dir)/connection/state.json"
    [ -f "$state" ] || return 0
    target=$(jq -r '.target // ""' "$state")
    wipe=$(jq -r '.wipe // ""' "$state")
    [ -z "$target" ] || { [ "$target" = "$1" ] && [ "$wipe" = "$2" ]; }
}
