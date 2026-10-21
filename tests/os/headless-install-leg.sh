# shellcheck shell=bash
# shellcheck disable=SC2154 # jar, ip and disk paths belong to the calling phase.
headless_install_stage() {
    local loop mnt tries=0 rc=0
    loop=$(losetup -Pf --show "$DISK") || return 1
    while [ ! -e "${loop}p1" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d) || {
        losetup -d "$loop"
        return 1
    }
    if mount "${loop}p1" "$mnt"; then
        if [ "$#" = 0 ]; then
            rm -f "$mnt/pithead-token.txt" "$mnt/pithead-config.json" || rc=1
        else
            printf '%s\n' 'PiT-K7m2Qx' >"$mnt/pithead-token.txt" &&
                printf '%s' "$1" >"$mnt/pithead-config.json" || rc=1
        fi
        umount "$mnt" || rc=1
    else
        rc=1
    fi
    rmdir "$mnt" || rc=1
    losetup -d "$loop" || rc=1
    return "$rc"
}

headless_install_auth() {
    local variant
    for variant in PiT-K7m2Qx pit-k7m2qx PIT-K7M2QX k7m2qx K7M2QX; do
        rm -f "$jar"
        if ! curl -fsSk -m 10 -c "$jar" --data-urlencode "token=$variant" "https://$ip/auth" -o /dev/null 2>/dev/null ||
            ! grep -q wizard_session "$jar"; then
            bad "staged setup token authenticates with supported case and prefix variants (#3071)"
            return 1
        fi
    done
    ok "staged setup token authenticates with supported case and prefix variants (#3071)"
}

headless_install_prefill_valid() {
    jq -e --argjson staged "$2" '
        .mode == "installer" and .stage == "installer" and .new_machine == false and
        .install_attempt == {} and ((.config * $staged) == .config)' <<<"$1" >/dev/null
}

headless_install_blank_valid() {
    jq -e '.mode == "installer" and .stage == "installer" and .new_machine == true and
        .install_attempt == {} and (.reference.monero.wallet_address | type) == "string" and
        (.reference.tari.wallet_address | type) == "string" and
        .config.monero.wallet_address == .reference.monero.wallet_address and
        .config.tari.wallet_address == .reference.tari.wallet_address' <<<"$1" >/dev/null
}

headless_install_rejection() {
    _ssh "printf '%s' '{malformed' >/boot/efi/pithead-config.json && sync" || return 1
    : >"$SERIAL"
    _reboot_wait reboot 300 && _wait_setup_page 180 || {
        bad "installer setup page returns after reboot with malformed preseed (#3071)"
        return 1
    }
    headless_install_auth || return 1
    local state_json
    state_json=$(curl -fsSk -m 10 -b "$jar" "https://$ip/api/wizard-state" 2>/dev/null) || state_json=""
    if wait_serial 'pre-seeded configuration was rejected' 30 && headless_install_blank_valid "$state_json"; then
        ok "malformed installer preseed is announced and opens a blank form with no disk selected (#3071)"
    else
        bad "malformed installer preseed is announced and opens a blank form with no disk selected (#3071)"
        return 1
    fi
}
