# shellcheck shell=bash
lan_guard_marker_path() {
    local dir
    dir=$(env_get LAN_GUARD_DIR 2>/dev/null)
    if [ -n "$dir" ]; then
        printf '%s/enforced' "$dir"
    else
        case "$LAN_GUARD_MARKER" in
        /*) printf '%s' "$LAN_GUARD_MARKER" ;;
        *) printf '%s/%s' "$PWD" "$LAN_GUARD_MARKER" ;;
        esac
    fi
}

chain_runtime_config_dir() {
    local digest
    digest=$({
        sha256sum build/tari/config.toml.template build/tari/entrypoint.sh || return 1
        printf '%s\n%s\n' "$TARI_ONION" "$NETWORK_PREFIX"
    } | sha256sum | cut -d' ' -f1) || return 1
    printf '%s/%s' "$TARI_CONFIG_ROOT" "$digest"
}

prepare_chain_runtime_state() {
    local old stage
    old=$(env_get CLEARNET_STATE_DIR 2>/dev/null)
    [ -n "$old" ] || old="$PWD/data/clearnet-state"
    if [ "$old" != "$CLEARNET_STATE_DIR" ] && [ -d "$old" ]; then
        [ ! -L "$old" ] || error "The previous clearnet state directory is a symlink."
        if [ -n "$(ls -A "$old")" ]; then
            if [ -d "$CLEARNET_STATE_DIR" ] && [ -n "$(ls -A "$CLEARNET_STATE_DIR")" ]; then
                [ ! -L "$CLEARNET_STATE_DIR" ] && diff -r "$old" "$CLEARNET_STATE_DIR" >/dev/null ||
                    error "Both clearnet state locations contain data; refusing to overwrite transition state."
            else
                [ ! -e "$CLEARNET_STATE_DIR" ] || rmdir "$CLEARNET_STATE_DIR" || return 1
                docker compose stop dashboard || error "Could not stop the dashboard before carrying clearnet transition state."
                mkdir -p "$(dirname "$CLEARNET_STATE_DIR")" || return 1
                stage=$(mktemp -d "${CLEARNET_STATE_DIR}.XXXXXX") || return 1
                if ! cp -a "$old/." "$stage/" || ! diff -r "$old" "$stage" >/dev/null; then
                    error "Could not verify the copied clearnet transition state; the previous directory is retained."
                fi
                mv "$stage" "$CLEARNET_STATE_DIR" || return 1
            fi
        fi
    fi
    for stage in "$CLEARNET_STATE_DIR" "$LAN_GUARD_DIR" "$TARI_CONFIG_ROOT"; do
        [ ! -L "$stage" ] || error "A chain runtime directory is a symlink."
        mkdir -p "$stage" || return 1
    done
    sudo chown root:root "$CLEARNET_STATE_DIR" && sudo chmod 1777 "$CLEARNET_STATE_DIR" ||
        error "Could not secure clearnet transition state directory."
}

install_chain_runtime_config() {
    local target expected stage short
    target=$(env_get TARI_CONFIG_DIR)
    expected=$(chain_runtime_config_dir) || return 1
    [ "$target" = "$expected" ] || error "Tari runtime inputs changed after environment rendering; render again."
    [ ! -L "$target" ] || error "The Tari runtime configuration is a symlink."
    stage=$(mktemp -d "$TARI_CONFIG_ROOT/.render.XXXXXX") || return 1
    short="${TARI_ONION%%.*}"
    cp build/tari/config.toml.template "$stage/config.toml" &&
        safe_sed "s/<your_tari_onion_address_no_extension>/$short/g" "$stage/config.toml" &&
        safe_sed "s/172\.28\.0/$NETWORK_PREFIX/g" "$stage/config.toml" &&
        cp build/tari/entrypoint.sh "$stage/entrypoint.sh" &&
        chmod 755 "$stage" "$stage/entrypoint.sh" && chmod 644 "$stage/config.toml" || return 1
    if [ -d "$target" ]; then
        diff -r "$stage" "$target" >/dev/null || error "The existing Tari runtime configuration differs from its content identity."
        [ -x "$target/entrypoint.sh" ] || error "The existing Tari runtime entrypoint is not executable."
        rm -f "$stage/config.toml" "$stage/entrypoint.sh" && rmdir "$stage"
    else
        mv "$stage" "$target" || return 1
    fi
}
