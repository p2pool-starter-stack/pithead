# shellcheck shell=bash
# The pinned v6 wallet's GetCompleteAddress returns the actual database's addresses.
# Accept only a complete, uncompressed unary response with bounded length-delimited fields.
legacy_response_matches() {
    local file="$1" expected="$2" length tag size shift byte i value match=1
    local -a bytes
    read -r -a bytes <<<"$(od -An -v -tu1 "$file" | tr '\n' ' ')"
    [ "${#bytes[@]}" -ge 5 ] && [ "${bytes[0]}" = 0 ] || return 1
    length=$((bytes[1] * 16777216 + bytes[2] * 65536 + bytes[3] * 256 + bytes[4]))
    [ "$length" -gt 0 ] && [ "$length" -le 4096 ] && [ "${#bytes[@]}" = "$((length + 5))" ] || return 1
    i=5
    while [ "$i" -lt "${#bytes[@]}" ]; do
        tag=${bytes[i]}
        i=$((i + 1))
        case "$tag" in 10 | 18 | 26 | 34 | 42 | 50) ;; *) return 1 ;; esac
        size=0 shift=0
        while :; do
            [ "$i" -lt "${#bytes[@]}" ] && [ "$shift" -le 7 ] || return 1
            byte=${bytes[i]}
            i=$((i + 1))
            size=$((size + ((byte & 127) << shift)))
            [ "$byte" -ge 128 ] || break
            shift=$((shift + 7))
        done
        [ "$((i + size))" -le "${#bytes[@]}" ] || return 1
        if [ "$tag" = 26 ] || [ "$tag" = 34 ]; then
            value=''
            while [ "$size" -gt 0 ]; do
                byte=${bytes[i]}
                i=$((i + 1))
                size=$((size - 1))
                # Base58 is printable ASCII; refuse embedded controls and NULs.
                [ "$byte" -ge 33 ] && [ "$byte" -le 126 ] || return 1
                printf -v byte '\\%03o' "$byte"
                printf -v byte '%b' "$byte"
                value+="$byte"
            done
            [ -n "$expected" ] && [ "$value" = "$expected" ] && match=0
        else
            i=$((i + size))
        fi
    done
    return "$match"
}

# setpriv starts as the wrapper uid before dropping to 1000. Try the parent first;
# after the drop, signal as the child uid because the wrapper has no CAP_KILL.
legacy_probe_signal() {
    kill "$1" "$2" 2>/dev/null ||
        setpriv --reuid=1000 --regid=1000 --clear-groups bash -c 'kill "$1" "$2"' _ "$1" "$2"
}

# Probe a private copy: even an unreadable or mismatching legacy DB stays byte-for-byte intact.
legacy_address_matches() (
    set -eu
    local db="$1" probe pid='' suffix attempt headers
    # Multiple legacy databases have ambiguous ownership; never choose one arbitrarily.
    [ -f "$db" ] && [ ! -L "$db" ] || exit 1
    probe=$(mktemp -d "$WALLET_DIR/.legacy-probe.XXXXXX") || exit 1
    trap '[ -z "$pid" ] || { legacy_probe_signal -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }; rm -rf "$probe"' EXIT
    trap 'exit 1' INT TERM
    mkdir -p "$probe/mainnet/data/wallet/db"
    for suffix in '' -wal -shm; do
        [ ! -e "$db$suffix" ] || cp "$db$suffix" "$probe/mainnet/data/wallet/db/console_wallet.db$suffix" || exit 1
    done
    chown -R 1000:1000 "$probe" || exit 1
    # The password unlocks the copied database. Configured creation keys cannot seed a probe.
    unset MINOTARI_WALLET_VIEW_PRIVATE_KEY MINOTARI_WALLET_SPEND_KEY
    setpriv --reuid=1000 --regid=1000 --clear-groups minotari_console_wallet \
        --base-path "$probe" --non-interactive-mode --enable-grpc \
        --grpc-address /ip4/127.0.0.1/tcp/18144 \
        -p wallet.http_server_url=http://127.0.0.1:1 \
        -p wallet.fallback_http_server_url=http://127.0.0.1:1 \
        >"$probe/output" 2>&1 &
    pid=$!
    for ((attempt = 0; attempt < 30; attempt++)); do
        legacy_probe_signal -0 "$pid" 2>/dev/null || exit 1
        if headers=$(printf '\000\000\000\000\000' | curl -fsS --http2-prior-knowledge --max-time 1 \
            --max-filesize 4096 -D - -o "$probe/response" \
            -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
            http://127.0.0.1:18144/tari.rpc.Wallet/GetCompleteAddress 2>/dev/null) &&
            printf '%s\n' "$headers" | tr -d '\r' | grep -qi '^grpc-status: *0$'; then
            legacy_response_matches "$probe/response" "${TARI_WALLET_ADDRESS:-}"
            exit $?
        fi
        sleep 1
    done
    exit 1
)
