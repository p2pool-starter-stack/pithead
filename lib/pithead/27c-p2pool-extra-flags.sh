validate_p2pool_extra_flags() {
    local reason
    if ! reason=$(jq -r '
        def fail($message): error("p2pool.extra_flags: " + $message);
        (if (.p2pool | has("extra_flags")) then .p2pool.extra_flags else [] end) as $flags
        | if ($flags | type) != "array" then fail("must be an array of strings")
          else . end
        | .monero.mode as $mode
        | $flags[]
        | if type != "string" then fail("each entry must be a string") else . end
        | if test("^--[a-z0-9-]+( [A-Za-z0-9][A-Za-z0-9_.:,-]*)?\\z") | not
          then fail("use one flag and at most one space-separated value; shell characters and whitespace are forbidden")
          else . end
        | split(" ") as $parts | $parts[0] as $flag | ($parts[1] // "") as $value
        | if ($flag == "--mini" or $flag == "--nano") then fail($flag + " is owned by p2pool.pool")
          elif ($flag | startswith("--socks5")) then fail($flag + " is owned by p2pool.clearnet")
          elif ($flag == "--wallet" or $flag == "--subaddress") then fail($flag + " is owned by monero.wallet_address and the payout policy")
          elif ($flag == "--host" or ($flag | startswith("--rpc-")) or $flag == "--zmq-port") then fail($flag + " is owned by monero.mode and monero.remote")
          elif $flag == "--merge-mine" then fail($flag + " is owned by tari.mode and tari.wallet_address")
          elif $flag == "--onion-address" then fail($flag + " is owned by the Tor profile")
          elif ($flag == "--stratum" or ($flag | startswith("--tls-")) or $flag == "--upnp-stratum" or $flag == "--start-mining") then fail($flag + " is owned by p2pool.stratum_bind and the miner profile")
          elif $flag == "--p2p" then fail($flag + " is owned by p2pool.pool and the network profile")
          elif ($flag == "--data-api" or $flag == "--local-api" or $flag == "--stratum-api") then fail($flag + " is owned by the data API profile")
          elif ($flag == "--no-clearnet-p2p" or $flag == "--no-upnp" or $flag == "--no-igd") then fail($flag + " is owned by the network profile")
          elif $flag == "--light-mode" then fail($flag + " is owned by the RAM profile")
          elif ($flag == "--data-dir" or $flag == "--log-file" or $flag == "--no-log-file" or $flag == "--disable-log") then fail($flag + " is owned by p2pool.data_dir and the logging profile")
          elif ($flag == "--no-dns" or $flag == "--no-console-log" or $flag == "--no-cache" or $flag == "--no-color" or $flag == "--no-randomx" or $flag == "--full-validation") then
            if $value != "" then fail($flag + " takes no value")
            elif $flag == "--no-randomx" and $mode == "remote" then fail("--no-randomx requires monero.mode local; remote PoW checks would use node RPC")
            else empty end
          elif ($flag == "--loglevel" or $flag == "--out-peers" or $flag == "--in-peers" or $flag == "--in-peers-localhost" or $flag == "--p2p-external-port") then
            if ($value | test("^[0-9]{1,5}\\z") | not) then fail($flag + " needs an integer value")
            elif $flag == "--loglevel" and ($value | tonumber) > 6 then fail("--loglevel must be 0–6")
            elif $flag == "--p2p-external-port" and (($value | tonumber) < 1 or ($value | tonumber) > 65535) then fail("--p2p-external-port must be 1–65535")
            elif $flag != "--loglevel" and $flag != "--p2p-external-port" and (($value | tonumber) < 10 or ($value | tonumber) > 450) then fail($flag + " must be 10–450")
            else empty end
          elif $flag == "--addpeers" then
            if ($value | test("^[A-Za-z0-9][A-Za-z0-9_.-]*:[0-9]{1,5}(,[A-Za-z0-9][A-Za-z0-9_.-]*:[0-9]{1,5})*\\z") | not) then fail("--addpeers needs comma-separated host:port pairs (no IPv6 brackets)")
            elif any($value | split(",")[] | split(":")[1] | tonumber; . < 1 or . > 65535) then fail("--addpeers ports must be 1–65535")
            else empty end
          else fail($flag + " is not allowlisted for P2Pool v4.18.1") end
    ' "$CONFIG_FILE" 2>&1); then
        error "$reason"
    fi
}

append_p2pool_extra_flags() {
    local flags="$1" extra
    while IFS= read -r extra; do
        if [ "$extra" = --no-dns ]; then
            case " $flags " in *' --no-dns '*) continue ;; esac
        fi
        flags="${flags:+$flags }$extra"
    done < <(jq -r '.p2pool.extra_flags // [] | .[]' "$CONFIG_FILE")
    printf '%s' "$flags"
}

p2pool_proxy_options() {
    printf '%s\n' "$1" | awk '{for (i=1;i<=NF;i++) if ($i == "--socks5" || $i == "--socks5-proxy-type") {printf "%s %s ", $i, $(i+1); i++}}'
}

p2pool_network_options() {
    printf '%s\n' "$1" | awk '{for (i=1;i<=NF;i++) if ($i == "--no-dns") {printf "%s ", $i} else if ($i == "--addpeers" || $i == "--p2p-external-port") {printf "%s %s ", $i, $(i+1); i++}}'
}
