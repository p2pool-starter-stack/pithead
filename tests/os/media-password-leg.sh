# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154 # dashboard_curl reads the phase credentials through dynamic scope.
media_password_recovery() {
    local stick="${DISK%.img}-media-password.img" new_pass=os3073-recovered-password
    local DASH_USER="$1" DASH_PASS="$2" old_pass="$2" deadline old_code=000 new_code=000 stick_rc=0
    _make_media_stick "$stick" "{\"dashboard\":{\"auth\":{\"password\":\"$new_pass\"}}}" &&
        _attach_media_stick "$stick" || {
        bad "password recovery stick could not be prepared or attached (#3073)"
        return 1
    }
    : >"$SERIAL"
    _reboot_wait reboot 300 && _wait_ssh 180 || {
        bad "password recovery boot did not return (#3073)"
        return 1
    }
    if ! wait_serial 'Media configuration channel: applied' 300 ||
        ! serial_has 'dashboard.auth.password' || serial_has "$new_pass"; then
        bad "USB password recovery names the setting without exposing its value (#3073)"
        return 1
    fi
    ok "USB password recovery names the setting without exposing its value (#3073)"
    deadline=$(($(date +%s) + 900))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        DASH_PASS="$new_pass"
        new_code=$(dashboard_curl -ksS -m 8 -o /dev/null -w '%{http_code}' "https://$ip/" 2>/dev/null || true)
        DASH_PASS="$old_pass"
        old_code=$(dashboard_curl -ksS -m 8 -o /dev/null -w '%{http_code}' "https://$ip/" 2>/dev/null || true)
        case "$old_code:$new_code" in 401:2??) break ;; esac
        sleep 10
    done
    case "$old_code:$new_code" in
    401:2??) ok "USB password recovery rejects the old login and accepts the new login (#3073)" ;;
    *)
        bad "USB password recovery login transition failed (old HTTP $old_code, new HTTP $new_code, #3073)"
        return 1
        ;;
    esac
    _detach_media_stick || {
        bad "password recovery stick could not be detached (#3073)"
        return 1
    }
    _media_stick_has_config "$stick" || stick_rc=$?
    if [ "$stick_rc" = 1 ]; then
        ok "USB password recovery consumes its settings file (#3073)"
    else
        bad "USB password recovery settings file remains or could not be read (#3073)"
        return 1
    fi
    rm -f "$stick"
}
