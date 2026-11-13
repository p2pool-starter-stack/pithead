os_release_tag_valid() { printf '%s' "${1:-}" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; }

os_release_host_ok() {
    case "$1" in
    https://api.github.com/* | https://github.com/* | https://objects.githubusercontent.com/* | https://release-assets.githubusercontent.com/*) return 0 ;;
    esac
    return 1
}

os_channel_www_at() {
    awk -v t="${1:-0}" 'BEGIN { print strftime("%Y-%m-%dT%H:%M:%SZ", t) }' 2>/dev/null || printf 'epoch %s' "${1:-0}"
}

os_channel_fetch() {
    local mode="$1" url="$2" out="$3" cap="$4" socks="${5:-}"
    local base tmp="" hdr hop=0 probe rc code redir curl_out
    local -a argv
    OS_CHANNEL_HINT=""
    base=$(os_update_test_base) || base=""
    if [ -n "$base" ]; then
        [ "${url#"$base"/}" != "$url" ] || {
            OS_CHANNEL_HINT="refused a fetch to a URL that is neither the release channel nor the test seam — nothing was changed."
            return 1
        }
        socks=""
    else
        os_release_host_ok "$url" || {
            OS_CHANNEL_HINT="refused a fetch outside the release hosts — the update channel dials only the release hosts over https, and nothing was changed."
            return 1
        }
        [ -n "$socks" ] || {
            OS_CHANNEL_HINT="the update channel fetches only through the Tor SOCKS proxy — nothing was changed."
            return 1
        }
    fi
    [ "$mode" = head ] || tmp="$out.channel.tmp.$$"
    hdr=$(mktemp "${TMPDIR:-/tmp}/pithead-channel-hdr.XXXXXX") || return 1
    while :; do
        hop=$((hop + 1))
        if [ "$hop" -gt 5 ]; then
            OS_CHANNEL_HINT="the update channel redirected more than five times — the fetch was refused and nothing was changed."
            rm -f "$tmp" "$hdr"
            return 1
        fi
        if [ "$mode" = head ]; then
            curl_out=$(mktemp "${TMPDIR:-/tmp}/pithead-channel-head.XXXXXX") || {
                rm -f "$hdr"
                return 1
            }
        else
            curl_out="$tmp"
        fi
        argv=(curl -sS --max-time "${PITHEAD_OS_CHANNEL_TIMEOUT:-60}" --max-filesize "$cap" -D "$hdr" -w '%{http_code}')
        if [ "$mode" = head ]; then
            argv+=(-I)
        fi
        argv+=(-o "$curl_out")
        if [ -n "$socks" ]; then
            argv+=(--proto "=https" --socks5-hostname "$socks")
        fi
        argv+=("$url")
        probe=$("${argv[@]}" 2>/dev/null) && rc=0 || rc=$?
        case "$rc" in
        0) ;;
        28)
            OS_CHANNEL_HINT="the update channel fetch timed out — nothing was changed."
            rm -f "$hdr" "$curl_out"
            if [ -n "$tmp" ]; then rm -f "$tmp"; fi
            return 28
            ;;
        63)
            OS_CHANNEL_HINT="the update channel response exceeded its $cap-byte size cap — the fetch was refused and nothing was changed."
            rm -f "$hdr" "$curl_out"
            if [ -n "$tmp" ]; then rm -f "$tmp"; fi
            return 63
            ;;
        *)
            OS_CHANNEL_HINT="the update channel could not be reached (curl exit $rc) — nothing was changed."
            rm -f "$hdr" "$curl_out"
            if [ -n "$tmp" ]; then rm -f "$tmp"; fi
            return 1
            ;;
        esac
        code="$probe"
        redir=$(sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//p' "$hdr" 2>/dev/null | tr -d '\r' | tail -1)
        case "$code" in
        2??)
            rm -f "$hdr"
            if [ "$mode" = head ]; then
                printf '%s' "$url"
                rm -f "$curl_out"
                return 0
            fi
            mv "$tmp" "$out"
            return 0
            ;;
        3??)
            rm -f "$curl_out"
            if [ -n "$base" ]; then
                [ "${redir#"$base"/}" != "$redir" ] || {
                    OS_CHANNEL_HINT="the update channel redirected off the test seam — the fetch was refused and nothing was changed."
                    rm -f "$hdr"
                    if [ -n "$tmp" ]; then rm -f "$tmp"; fi
                    return 1
                }
            else
                os_release_host_ok "$redir" || {
                    OS_CHANNEL_HINT="the update channel redirected off the release hosts — the fetch was refused and nothing was changed."
                    rm -f "$hdr"
                    if [ -n "$tmp" ]; then rm -f "$tmp"; fi
                    return 1
                }
            fi
            url="$redir"
            ;;
        *)
            OS_CHANNEL_HINT="the update channel answered HTTP $code — nothing was changed."
            rm -f "$hdr" "$curl_out"
            if [ -n "$tmp" ]; then rm -f "$tmp"; fi
            return 1
            ;;
        esac
    done
}

os_channel_state_file() { printf '%s/channel.json' "$(os_update_staging_dir)"; }

os_channel_record() {
    local f tag="$1" now prev high moved_at seen moved regressed note
    f=$(os_channel_state_file)
    now="${2:-$(date +%s)}"
    printf '%s' "$now" | grep -qE '^[0-9]+$' || return 1
    os_release_tag_valid "$tag" || return 1
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    prev=""
    if [ -f "$f" ]; then
        prev=$(jq -r '.tag // ""' "$f" 2>/dev/null) || prev=""
        moved_at=$(jq -r '.moved_at // 0' "$f" 2>/dev/null) || moved_at=0
    else
        moved_at=0
    fi
    high="$prev"
    moved=true
    regressed=false
    if [ "$prev" = "$tag" ]; then
        moved=false
    elif [ -n "$prev" ] && os_semver_ok "${prev#v}" && os_semver_ok "${tag#v}" && semver_newer "$prev" "$tag"; then
        moved=false
        regressed=true
    fi
    seen="$now"
    if [ "$moved" = true ]; then
        high="$tag"
        moved_at="$now"
    fi
    if [ "$regressed" = true ]; then
        note="the release channel offered $tag after its last listing showed $high on $(os_channel_www_at "$moved_at") — treat this as a possible replayed listing."
    elif [ "$moved" = false ]; then
        note="the release channel has not advanced since $(os_channel_www_at "$moved_at") — it may be stale or frozen."
    else
        note=""
    fi
    if ! jq -n --arg t "$high" --argjson m "$moved_at" --argjson s "$seen" --argjson mv "$moved" \
        --argjson rg "$regressed" --arg n "$note" \
        '{tag:$t,moved_at:$m,seen:$s,moved:$mv,regressed:$rg,note:$n}' >"$f.tmp" 2>/dev/null ||
        ! mv -f "$f.tmp" "$f" 2>/dev/null; then
        rm -f "$f.tmp"
        return 1
    fi
    printf '%s' "$(cat "$f")"
}
