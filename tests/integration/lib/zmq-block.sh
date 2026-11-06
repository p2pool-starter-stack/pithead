# shellcheck shell=bash

zmq_block_subscribe_lines() {
    printf 'deadline=$((SECONDS + %s))\n' "$1"
    cat <<'EOF'
export LC_ALL=C
printf '\x00\x18\x01json-minimal-chain_main' >&3
block_read() {
    local remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || return 1
    local data
    data=$(timeout "$remaining" head -c "$1" <&3 | od -An -v -tx1 | tr -d ' \n')
    [ "${#data}" -eq "$(($1 * 2))" ] || return 1
    printf '%s' "$data"
}
while [ "$SECONDS" -lt "$deadline" ]; do
    hdr=$(block_read 2) || break
    case "${hdr:0:2}" in
    00) size=$((16#${hdr:2:2})) ;;
    02)
        rest=$(block_read 7) || break
        length="${hdr:2:2}$rest"
        [ "${length:0:10}" = 0000000000 ] || break
        size=$((16#$length))
        ;;
    *) break ;;
    esac
    [ "$size" -gt 0 ] && [ "$size" -le 65536 ] || break
    body=$(block_read "$size") || break
    message=$(printf '%b' "$(printf '%s' "$body" | sed 's/../\\x&/g')")
    [ "${#message}" -eq "$size" ] || break
    case "$message" in
    json-minimal-chain_main:*)
        if printf '%s' "${message#*:}" | jq -e -s '
            def hash: type == "string" and length == 64 and test("^[0-9a-fA-F]{64}$");
            length == 1 and (.[0] | type == "object" and
            (.first_height | type == "number" and . >= 0 and . == floor) and
            (.first_prev_id | hash) and
            (.ids | type == "array" and length > 0 and all(.[]; hash)))
        ' >/dev/null 2>&1; then
            echo 'BLOCK valid'
            break
        fi
        echo 'BLOCK malformed'
        break
        ;;
    esac
done
EOF
}

zmq_block_probe() {
    local host="$1" port="$2" budget="${3:-900}" out snippet
    snippet="$(zmq_probe_snippet "$host" "$port" 8 "$budget" block)"
    if ! out=$(rx "timeout $((budget + 50)) bash -c $(quote_arg "$snippet")" 2>/dev/null); then
        echo 'block-observation-failed transport or observer did not complete'
        return 1
    fi
    zmq_pub_verdict "$out" "$host" "$port" >/dev/null || {
        echo 'block-observation-failed publisher handshake rejected'
        return 1
    }
    if [ "$(printf '%s\n' "$out" | sed -n 's/^BLOCK //p')" = valid ]; then
        echo 'ok observed a complete json-minimal-chain_main block notification'
        return 0
    fi
    echo 'block-not-observed no valid complete block notification within the bounded observation'
    return 1
}

assert_zmq_block() {
    local verdict
    if verdict=$(zmq_block_probe "$1" "$2"); then
        it_pass 'monero ZMQ published frame is a BLOCK notification'
    else
        it_fail 'monero ZMQ published frame is a BLOCK notification' "$verdict"
    fi
}
