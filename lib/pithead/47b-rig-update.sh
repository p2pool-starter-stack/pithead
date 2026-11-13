rig_update_state_file() { printf '%s' "${PITHEAD_RIG_UPDATE_STATE:-$PWD/rig-update.json}"; }

rig_update_pending() {
    local f
    f=$(rig_update_state_file)
    [ -f "$f" ] || return 0
    jq -r 'select(.state == "pending") | .to // empty' "$f" 2>/dev/null || true
}

rig_update_state_write() { # <state> <from> <to> <reason>
    local f tmp
    f=$(rig_update_state_file)
    tmp="$f.tmp"
    if jq -n --arg st "$1" --arg fr "$2" --arg t "$3" --arg r "$4" --argjson ts "$(date +%s)" \
        '{state:$st,from:$fr,to:$t,ts:$ts} + (if $r == "" then {} else {reason:$r} end)' \
        >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
}

rig_update_refuse() { # <reason> [target]
    if [ -z "$(rig_update_pending)" ]; then
        rig_update_state_write refused "$(os_running_version)" "${2:-}" "$1"
    fi
    error "$1"
}

rig_update_gate() {
    command -v rauc >/dev/null 2>&1 ||
        error "rauc is not available here — rig-update applies to the appliance rig image, not a checkout install."
    local role
    role=$(machine_role)
    [ "$role" = "rig" ] ||
        error "rig-update runs on a rig — this machine is '$role'. A coordinator updates its OS with 'pithead os-update' or the dashboard."
}

rig_update_tor_wrap() { # <subcommand args...> — 127 when the body runs directly, else the wrapped run's rc
    if os_update_test_base >/dev/null 2>&1; then return 127; fi
    if [ "${PITHEAD_RIG_UPDATE_IN_TOR:-}" = 1 ]; then return 127; fi
    command -v pithead-tor >/dev/null 2>&1 || return 126
    local rc=0
    PITHEAD_RIG_UPDATE_IN_TOR=1 pithead-tor "$0" rig-update "$@" || rc=$?
    return "$rc"
}

rig_update_channel_url() { # <tag-or-empty>
    local base
    if base=$(os_update_test_base); then
        printf '%s' "$base/releases-latest.json"
        return 0
    fi
    if [ -n "${1:-}" ]; then
        printf '%s' "https://api.github.com/repos/p2pool-starter-stack/pithead/releases/tags/$1"
    else
        printf '%s' "https://api.github.com/repos/p2pool-starter-stack/pithead/releases/latest"
    fi
}

rig_update_release() { # <tag-or-empty> — sets RIG_TAG RIG_SIZE RIG_NOTE; a refusal reason lands in RIG_REFUSE
    local url tmp rc=0 size note_json
    RIG_TAG="" RIG_SIZE=0 RIG_NOTE="" RIG_REFUSE=""
    url=$(rig_update_channel_url "${1:-}")
    tmp=$(mktemp "${TMPDIR:-/tmp}/pithead-rigrel.XXXXXX") || {
        RIG_REFUSE="the release channel response could not be staged — nothing was changed."
        return 1
    }
    os_channel_fetch get "$url" "$tmp" "$CURL_CAP_SMALL" "127.0.0.1:${PITHEAD_TOR_SOCKS_PORT:-9253}" || rc=$?
    if [ "$rc" -ne 0 ]; then
        RIG_REFUSE="${OS_CHANNEL_HINT:-the release channel could not be read — nothing was changed.}"
        rm -f "$tmp"
        return 1
    fi
    RIG_TAG=$(jq -r '.tag_name // ""' "$tmp" 2>/dev/null) || RIG_TAG=""
    if ! os_release_tag_valid "$RIG_TAG"; then
        RIG_REFUSE="the release channel published no usable release tag — nothing was changed."
        rm -f "$tmp"
        return 1
    fi
    size=$(jq -r --arg n "pithead-os-$RIG_TAG.raucb" '[.assets[]? | select(.name == $n)][0].size // 0' "$tmp" 2>/dev/null) || size=0
    case "$size" in '' | *[!0-9]*) size=0 ;; esac
    if [ "$size" -le 0 ]; then
        RIG_REFUSE="release $RIG_TAG publishes no appliance OS bundle — nothing was changed."
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    RIG_SIZE="$size"
    note_json=$(os_channel_record "$RIG_TAG" 2>/dev/null) || note_json=""
    RIG_NOTE=$(printf '%s' "$note_json" | jq -r '.note // ""' 2>/dev/null) || RIG_NOTE=""
    return 0
}

rig_update_slot_guard() {
    local status bs
    status=$(rauc status --output-format=json 2>/dev/null) || {
        RIG_REFUSE="this machine's slot state could not be read — nothing was changed."
        return 1
    }
    bs=$(printf '%s' "$status" |
        jq -r '(.booted // "") as $b | [.slots[]? | to_entries[]? |
            select(.value.bootname != null and .value.bootname != $b) | .value.boot_status // ""] | .[0] // ""' 2>/dev/null) || bs=""
    case "$bs" in
    good | bad | "") return 0 ;;
    unknown)
        if [ -f .boot-gate-failures ]; then
            RIG_REFUSE="the other slot is uncommitted and a boot here failed its gate — read 'journalctl -u pithead-boot' before installing over it; nothing was changed."
            return 1
        fi
        return 0
        ;;
    esac
    RIG_REFUSE="the other slot is uncommitted (rauc reports boot status '$bs') — a slot mid-flight is never overwritten; nothing was changed."
    return 1
}

rig_update_cleanup() { find "$(os_update_staging_dir)" -maxdepth 1 -name 'pithead-os-*.raucb*' -delete 2>/dev/null || true; }

rig_update_download() { # <final> <partial> <size> <url> <socks> — 0 only for a complete file at exactly <size>
    local final="$1" part="$2" size="$3" url="$4" socks="$5"
    local attempt="${PITHEAD_OS_DL_ATTEMPT:-600}" tries=0 pid rc=0 bytes have http_code fail
    while :; do
        tries=$((tries + 1))
        if [ "$tries" -gt "${PITHEAD_RIG_UPDATE_ATTEMPTS:-12}" ]; then
            RIG_REFUSE="the download did not finish in $((tries - 1)) attempts — the partial file was discarded and nothing was installed."
            return 1
        fi
        have=0
        if [ -f "$part" ]; then have=$(wc -c <"$part" | tr -d ' '); fi
        if [ -n "$socks" ]; then
            curl -fS -C - --max-time "$attempt" --max-filesize "$CURL_CAP_OS_BUNDLE" \
                --proto "=https" --socks5-hostname "$socks" -o "$part" -w '%{http_code}\n' \
                "$url" >"$part.code" 2>/dev/null &
        else
            curl -fS -C - --max-time "$attempt" --max-filesize "$CURL_CAP_OS_BUNDLE" \
                -o "$part" -w '%{http_code}\n' "$url" >"$part.code" 2>/dev/null &
        fi
        pid=$!
        wait "$pid" && rc=0 || rc=$?
        http_code=$(tr -d '[:space:]' <"$part.code" 2>/dev/null) || http_code=""
        rm -f "$part.code"
        bytes=0
        if [ -f "$part" ]; then bytes=$(wc -c <"$part" | tr -d ' '); fi
        fail=""
        if [ "$bytes" -gt "$size" ]; then fail="the bundle stream exceeded its announced $size-byte size"; fi
        if [ -z "$fail" ] && [ "$rc" -eq 0 ] && [ "${http_code#2}" = "$http_code" ]; then
            fail="the bundle URL answered HTTP ${http_code:-none}"
        fi
        if [ -n "$fail" ]; then
            RIG_REFUSE="$fail — the partial file was discarded and nothing was installed."
            return 1
        fi
        if [ "$rc" -eq 0 ]; then
            if [ "$bytes" -eq "$size" ]; then
                mv -f "$part" "$final"
                return 0
            fi
            RIG_REFUSE="the download completed at $bytes bytes but the release publishes $size — a truncated bundle is never verified as complete; the partial file was discarded."
            return 1
        fi
        if [ "$rc" -ne 28 ]; then
            RIG_REFUSE="the download failed over Tor at $bytes of $size bytes — the partial file was discarded and nothing was installed."
            return 1
        fi
        rc=0
    done
}

rig_update_check() {
    rig_update_gate
    local rc=0 running
    rig_update_tor_wrap check || rc=$?
    if [ "$rc" -ne 127 ]; then
        if [ "$rc" -eq 126 ]; then
            rig_update_refuse "this image carries no on-demand Tor client (pithead-tor) — rig-update needs it to reach the release channel."
        fi
        if [ "$rc" -ne 0 ]; then
            printf 'rig-update: the Tor helper ended with status %s — nothing was changed.\n' "$rc" >&2
        fi
        return "$rc"
    fi
    rig_update_release "" || rig_update_refuse "$RIG_REFUSE"
    running=$(os_running_version)
    printf 'rig-update: running v%s, release channel offers %s (%s bytes) — nothing installed.\n' \
        "$running" "$RIG_TAG" "$RIG_SIZE"
    if [ "$RIG_TAG" = "v$running" ]; then
        printf 'rig-update: this rig already runs %s.\n' "$RIG_TAG"
    fi
    if [ -n "$RIG_NOTE" ]; then
        printf 'rig-update: %s\n' "$RIG_NOTE"
    fi
    return 0
}

rig_update_install() {
    rig_update_gate
    local tag_wanted="" max_version="" arg rc=0 reason pending
    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
        --tag)
            [ "$#" -ge 2 ] || error "rig-update install --tag needs a tag. Run '$0 help'."
            tag_wanted="$2"
            shift 2
            ;;
        --max-version)
            [ "$#" -ge 2 ] || error "rig-update install --max-version needs a version. Run '$0 help'."
            max_version="$2"
            shift 2
            ;;
        *) error "Unknown option for rig-update install: $arg. Run '$0 help'." ;;
        esac
    done
    if [ -n "$tag_wanted" ] && ! os_release_tag_valid "$tag_wanted"; then
        rig_update_refuse "--tag wants the exact vX.Y.Z form (got '$tag_wanted') — nothing was changed."
    fi
    max_version="${max_version#v}"
    if [ -n "$max_version" ] && ! os_semver_ok "$max_version"; then
        rig_update_refuse "--max-version wants an X.Y.Z version (got '$max_version') — nothing was changed."
    fi
    pending=$(rig_update_pending)
    if [ -n "$pending" ]; then
        rig_update_refuse "an update to v$pending is already pending a reboot — reboot this rig before starting another; nothing was changed."
    fi
    rig_update_slot_guard || rig_update_refuse "$RIG_REFUSE"
    local -a wrap=(install)
    if [ -n "$tag_wanted" ]; then wrap+=(--tag "$tag_wanted"); fi
    if [ -n "$max_version" ]; then wrap+=(--max-version "$max_version"); fi
    rig_update_tor_wrap "${wrap[@]}" || rc=$?
    if [ "$rc" -ne 127 ]; then
        if [ "$rc" -eq 126 ]; then
            rig_update_refuse "this image carries no on-demand Tor client (pithead-tor) — rig-update needs it to reach the release channel."
        fi
        if [ "$rc" -ne 0 ]; then
            printf 'rig-update: the Tor helper ended with status %s — nothing was changed.\n' "$rc" >&2
        fi
        return "$rc"
    fi
    rig_update_release "$tag_wanted" || rig_update_refuse "$RIG_REFUSE"
    local target="${RIG_TAG#v}"
    if [ -n "$max_version" ] && semver_newer "$target" "$max_version"; then
        rig_update_refuse "$RIG_TAG is above --max-version v$max_version — nothing was installed." "$target"
    fi
    if [ "$RIG_TAG" = "v$(os_running_version)" ]; then
        rig_update_refuse "this rig already runs $RIG_TAG — nothing to install." "$target"
    fi
    reason=$(os_update_version_guard "$target" 0)
    if [ -n "$reason" ]; then
        rig_update_refuse "$reason" "$target"
    fi
    local osdir final part socks base url final_url have avail_kb need errf last_err=""
    osdir=$(os_update_staging_dir)
    mkdir -p "$osdir"
    final="$osdir/pithead-os-$RIG_TAG.raucb"
    part="$final.partial"
    find "$osdir" -maxdepth 1 -name 'pithead-os-*.raucb*' \
        ! -name "pithead-os-$RIG_TAG.raucb" ! -name "pithead-os-$RIG_TAG.raucb.partial" -delete 2>/dev/null || true
    have=0
    if [ -f "$part" ]; then have=$(wc -c <"$part" | tr -d ' '); fi
    avail_kb=$(df -Pk "$osdir" 2>/dev/null | awk 'NR==2{print $4}') || avail_kb=""
    case "$avail_kb" in '' | *[!0-9]*) avail_kb=0 ;; esac
    need=$(((RIG_SIZE - have) / 1024 + 1048576))
    if [ "$avail_kb" -lt "$need" ]; then
        rig_update_refuse "not enough free space on /data for the update bundle (need about $((need / 1024)) MiB free, have $((avail_kb / 1024)) MiB) — free space and retry; nothing was installed." "$target"
    fi
    if base=$(os_update_test_base); then
        url="$base/pithead-os-$RIG_TAG.raucb"
        final_url="$url"
        socks=""
    else
        socks="127.0.0.1:${PITHEAD_TOR_SOCKS_PORT:-9253}"
        url="https://github.com/p2pool-starter-stack/pithead/releases/download/$RIG_TAG/pithead-os-$RIG_TAG.raucb"
        final_url=$(os_channel_fetch head "$url" /dev/null "$CURL_CAP_OS_BUNDLE" "$socks") || final_url=""
        if [ -z "$final_url" ]; then
            rig_update_refuse "the update bundle URL could not be resolved over Tor — ${OS_CHANNEL_HINT:-nothing was changed.}" "$target"
        fi
    fi
    if ! rig_update_download "$final" "$part" "$RIG_SIZE" "$final_url" "$socks"; then
        rig_update_cleanup
        rig_update_refuse "$RIG_REFUSE" "$target"
    fi
    rc=0
    reason=$(os_verify_bundle_reason "$final" "$RIG_TAG") || rc=$?
    reason="${reason% The downloaded update was kept.}"
    if [ "$rc" -ne 0 ] || [ -n "$reason" ]; then
        rig_update_cleanup
        rig_update_refuse "${reason:-the bundle could not be verified — nothing was installed.}" "$target"
    fi
    printf 'rig-update: %s verified against this machine release keyring — writing it to the spare slot\n' "$RIG_TAG"
    errf=$(mktemp "${TMPDIR:-/tmp}/pithead-riginstall.XXXXXX") || errf=""
    rc=0
    if [ -n "$errf" ]; then
        (os_update "$final" -y </dev/null) 2>"$errf" || rc=$?
        last_err=$(tail -1 "$errf" 2>/dev/null | tr -d '[:cntrl:]' | head -c 300)
        rm -f "$errf"
    else
        (os_update "$final" -y </dev/null) || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        rig_update_cleanup
        rig_update_refuse "the verified bundle could not be installed${last_err:+ — rauc said: $last_err} — nothing was changed." "$target"
    fi
    rig_update_state_write pending "$(os_running_version)" "$target" ""
    rig_update_cleanup
    sync
    printf 'rig-update: v%s is written to the spare slot — rebooting now to boot it\n' "$target"
    ${PITHEAD_REBOOT_CMD:-systemctl reboot}
    return 0
}

rig_update_boot_record() { # rig boot calls this: sweep staged bundles, settle a pending verdict
    local f to from now tmp
    rm -f "$(os_update_staging_dir)"/pithead-os-*.raucb "$(os_update_staging_dir)"/*.partial
    f=$(rig_update_state_file)
    [ -f "$f" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    to=$(jq -r 'select(.state == "pending") | .to // empty' "$f" 2>/dev/null) || to=""
    [ -n "$to" ] || return 0
    from=$(jq -r '.from // ""' "$f" 2>/dev/null) || from=""
    now=$(date +%s)
    tmp="$f.tmp"
    if [ "$to" = "$(os_running_version)" ]; then
        if jq -n --arg fr "$from" --arg t "$to" --argjson ts "$now" \
            '{state:"updated",from:$fr,to:$t,ts:$ts}' >"$tmp" 2>/dev/null; then
            mv -f "$tmp" "$f"
            echo "pithead-boot: the rig's update to v$to booted with the miner up — verdict updated"
        else
            rm -f "$tmp"
        fi
        return 0
    fi
    rauc status mark-bad other >/dev/null 2>&1 || true
    sync
    if jq -n --arg fr "$from" --arg t "$to" --argjson ts "$now" \
        '{state:"rolled_back",from:$fr,to:$t,ts:$ts,reason:"the miner never came up on the updated slot — the bootloader fell back"}' \
        >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f"
        echo "pithead-boot: the rig's v$to update never committed — this boot runs the previous version, the failed slot is marked bad and the verdict recorded"
    else
        rm -f "$tmp"
    fi
    return 0
}

rig_update() {
    local sub="${1:-}"
    case "$sub" in
    boot-record)
        shift
        rig_update_boot_record "$@"
        ;;
    check)
        shift
        rig_update_check "$@"
        ;;
    install)
        shift
        rig_update_install "$@"
        ;;
    *)
        error "rig-update needs a subcommand: check, or install [--tag T] [--max-version V]. Run '$0 help'."
        ;;
    esac
}
