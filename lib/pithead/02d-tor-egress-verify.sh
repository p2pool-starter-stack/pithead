# --- Live Tor egress rule verification helpers (#2678) ------------------------------------------
# Tokenise one `iptables -S` rule line the way libxtables writes it: whitespace-separated tokens,
# where a value that needs it is written as a double-quoted run with `\"` and `\\` escapes. Prints
# one token per line, prefixed `b:` when it was written bare and `q:` when any of it came out of a
# quoted run. The caller needs that distinction: a quoted value is a value however much it spells
# a flag, which is the whole reason `-m string --string "! -s 0.0.0.0/0 x"` could not be read by
# any amount of substring scanning.
#
# rc 1 = the line cannot be read unambiguously (an unterminated quote, a trailing backslash). The
# caller reads that as shadowing: a rule we cannot parse is a rule we cannot clear.
tor_egress_tokenise() { # <rule line>
    local line="$1" n i=0 c tok="" have=0 quoted=0 closed
    n=${#line}
    while [ "$i" -lt "$n" ]; do
        c="${line:$i:1}"
        case "$c" in
        [[:space:]])
            if [ "$have" = 1 ]; then
                if [ "$quoted" = 1 ]; then printf 'q:%s\n' "$tok"; else printf 'b:%s\n' "$tok"; fi
                tok=""
                have=0
                quoted=0
            fi
            i=$((i + 1))
            ;;
        '"')
            i=$((i + 1))
            have=1
            quoted=1
            closed=0
            while [ "$i" -lt "$n" ]; do
                c="${line:$i:1}"
                if [ "$c" = '\' ]; then
                    i=$((i + 1))
                    [ "$i" -lt "$n" ] || return 1
                    tok="$tok${line:$i:1}"
                    i=$((i + 1))
                    continue
                fi
                if [ "$c" = '"' ]; then
                    closed=1
                    i=$((i + 1))
                    break
                fi
                tok="$tok$c"
                i=$((i + 1))
            done
            [ "$closed" = 1 ] || return 1
            ;;
        *)
            tok="$tok$c"
            have=1
            i=$((i + 1))
            ;;
        esac
    done
    if [ "$have" = 1 ]; then
        if [ "$quoted" = 1 ]; then printf 'q:%s\n' "$tok"; else printf 'b:%s\n' "$tok"; fi
    fi
    return 0
}

# Can this foreign DOCKER-USER rule decide a packet our DROP is meant to decide? rc 0 = yes, or we
# cannot prove otherwise; rc 1 = no, it cannot match the mining subnet. EVERY uncertain answer is
# rc 0: a line the tokeniser refuses, a `-s` value that is not a CIDR, a second `-s`, a flag whose
# value never arrived, or no `-s` at all (an unscoped ACCEPT matches everything, us included).
#
# TOKENS, not a substring scan — and not a scan with the quoted values stripped out first either.
# Three cuts of this check searched the raw line for `" -s "`, and each lost to a free-text match
# value containing it: `--comment` first, then `--comment` again past a strip that removed only
# the first clause (and only `--comment`), then `-m string --string`, which no amount of
# comment-stripping ever covered. There is no scan-shaped fix: ANY quoted value ahead of `-s`
# hijacks a positional search. Read left to right instead, where `-s` counts only as a bare token
# of its own, negation is a bare `!` immediately before it, and a quoted value is exactly one
# token that is never mistaken for the flag it spells.
tor_egress_rule_shadows() { # <rule line> <subnet>
    local line="$1" subnet="$2" tokens tok kind want="" seen=0 negated=0 prev="" foreign_net="" target=""
    tokens=$(tor_egress_tokenise "$line") || return 0
    while IFS= read -r tok; do
        kind="${tok%%:*}"
        tok="${tok#*:}"
        if [ -n "$want" ]; then
            case "$want" in
            s) foreign_net="$tok" ;;
            j) target="$tok" ;;
            esac
            want=""
            prev=""
            continue
        fi
        # A quoted token is a value. It can open nothing, negate nothing, and target nothing.
        if [ "$kind" = q ]; then
            prev=""
            continue
        fi
        case "$tok" in
        '!') prev='!' ;;
        -s | --source | --src)
            [ "$seen" = 0 ] || return 0 # two sources on one rule: we cannot say which one decides
            seen=1
            negated=0
            [ "$prev" != '!' ] || negated=1
            want=s
            prev=""
            ;;
        -j | --jump | -g | --goto)
            want=j
            prev=""
            ;;
        *) prev="" ;;
        esac
    done <<<"$tokens"
    [ -z "$want" ] || return 0 # a flag whose value never arrived
    # Unknown jump targets can terminate in an ACCEPT in another chain; fail closed on them.
    # LOG and the terminal deny targets cannot open clearnet before our DROP.
    case "$target" in
    DROP | REJECT | LOG | NFLOG) return 1 ;;
    *) ;;
    esac
    # DOCKER-USER is host-wide and shared with every other compose project (ufw-docker writes
    # there), so a rule that cannot match us must NOT be called shadowing, or the verdict fires
    # permanently on healthy hosts and stops meaning anything the one time it matters.
    [ "$seen" = 1 ] || return 0
    tor_egress_valid_cidr "$foreign_net" || return 0
    tor_egress_valid_cidr "$subnet" || return 0
    if [ "$negated" = 1 ]; then
        # A NEGATED accept matches every packet whose source is OUTSIDE <cidr> — the opposite test
        # from a plain match. It shadows unless the mining subnet sits ENTIRELY inside <cidr>:
        # a disjoint `! -s <unrelated>` matches OUR subnet precisely because it is disjoint.
        tor_egress_cidr_contains "$foreign_net" "$subnet" && return 1
        return 0
    fi
    tor_egress_cidr_overlaps "$foreign_net" "$subnet" && return 0
    return 1
}

tor_egress_sync_iptables_accept() { # <live -S line> <ip>; only our exact exception
    local line="$1" ip="$2" tokens i source="" chain="" module="" comment="" target=""
    local -a fields=()
    tokens=$(tor_egress_tokenise "$line") || return 1
    mapfile -t fields <<<"$tokens"
    [ "$((${#fields[@]} % 2))" = 0 ] || return 1
    for ((i = 0; i < ${#fields[@]}; i += 2)); do
        case "${fields[i]}" in
        b:-A)
            [ -z "$chain" ] && [ "${fields[i + 1]}" = b:DOCKER-USER ] || return 1
            chain=1
            ;;
        b:-s)
            [ -z "$source" ] || return 1
            source=${fields[i + 1]}
            ;;
        b:-m)
            [ -z "$module" ] && [ "${fields[i + 1]}" = b:comment ] || return 1
            module=1
            ;;
        b:--comment)
            [ -z "$comment" ] || return 1
            comment=${fields[i + 1]#?:}
            ;;
        b:-j)
            [ -z "$target" ] && [ "${fields[i + 1]}" = b:ACCEPT ] || return 1
            target=1
            ;;
        *) return 1 ;;
        esac
    done
    [ "$chain" = 1 ] && [ "$module" = 1 ] && [ "$comment" = "$TOR_EGRESS_TAG" ] &&
        [ "$target" = 1 ] && { [ "$source" = "b:$ip" ] || [ "$source" = "b:$ip/32" ]; }
}

tor_egress_iptables_canonical() { # <rule line>; compare generated rules despite -S option ordering
    local tokens i key value
    local -a fields=() pairs=()
    tokens=$(tor_egress_tokenise "$1") || return 1
    mapfile -t fields <<<"$tokens"
    [ "$((${#fields[@]} % 2))" = 0 ] || return 1
    for ((i = 0; i < ${#fields[@]}; i += 2)); do
        key=${fields[i]}
        [[ "$key" == b:-* ]] || return 1
        value=${fields[i + 1]#?:}
        [ "$key" != b:-s ] || value=${value%/32}
        [ "$key" != b:--ctstate ] || value=$(tr ',' '\n' <<<"$value" | LC_ALL=C sort | paste -sd, -)
        pairs+=("$key=$value")
    done
    printf '%s\n' "${pairs[@]}" | LC_ALL=C sort
}

tor_egress_sync_rules_match() { # <nft|iptables> <live rules>
    local backend="$1" out="$2" prefix subnet ip actual expected active line drop_seen
    local expected_rules expected_line canonical matched
    local -a sync_ips=()
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$prefix" ] || prefix=172.28.0
    subnet=$(env_get NETWORK_SUBNET 2>/dev/null)
    [ -n "$subnet" ] || subnet=172.28.0.0/24
    # A counted ACCEPT is ineffective after the subnet DROP: both backends decide in rule order.
    # The caller also checks that the DROP exists and is reached by forwarded traffic.
    active=$(tor_egress_sync_ips)
    if [ "$backend" = nft ]; then
        # This table is ours: a conditional ACCEPT for the whole subnet is still a public leak.
        jq -e --arg subnet "$subnet" --arg tor "$prefix.25" --arg active "$active" '
            def pfx($cidr): ($cidr | split("/") | {"prefix":{"addr":.[0],"len":(.[1] | tonumber)}});
            def ipmatch($field; $right): {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":$field}},"right":$right}};
            def safe($e):
                $e == [{"match":{"op":"==","left":{"ct":{"key":"direction"}},"right":"reply"}},
                    {"match":{"op":"in","left":{"ct":{"key":"state"}},"right":["established","related"]}}, {"accept":null}]
                or $e == [ipmatch("saddr"; $tor), {"accept":null}]
                or ($active | split("\n") | any(. != "" and $e == [ipmatch("saddr"; .), {"accept":null}]))
                or (["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10"]
                    | any($e == [ipmatch("saddr"; pfx($subnet)), ipmatch("daddr"; pfx(.)), {"accept":null}]))
                or (($e | length) == 3 and $e[0].match.op == "==" and $e[0].match.left.meta.key == "iifname"
                    and $e[1].match.op == "==" and $e[1].match.left.payload == {"protocol":"ip6","field":"daddr"}
                    and ($e[1].match.right == pfx("fc00::/7") or $e[1].match.right == pfx("fe80::/10"))
                    and $e[2] == {"accept":null});
            .nftables as $entries
            | ($entries | all(.[];
                if has("chain") then .chain.name == "forward"
                elif has("rule") then .rule.chain == "forward" and
                    (.rule.expr | length > 0 and (.[-1] | has("accept") or has("drop") or has("reject"))
                        and (.[0:-1] | all(.[]; has("match"))))
                else true end))
            and ([$entries[] | select(.rule?.chain == "forward") | .rule.expr]
                | any(. == [ipmatch("saddr"; pfx($subnet)), {"drop":null}]))
            and ([$entries[] | select(.rule?.chain == "forward") | .rule.expr | select(any(has("accept")))]
                | all(.[]; safe(.)))
        ' >/dev/null <<<"$out" || return 1
    fi
    for ip in "$prefix.26" "$prefix.27"; do
        if [ "$backend" = nft ]; then
            actual=$(jq --arg ip "$ip" '
                [.nftables[] | select(.rule?.chain == "forward") | .rule.expr] as $rules
                | ($rules | map(any(has("drop"))) | index(true)) as $drop
                | [range(0; $rules | length) as $n | $rules[$n]
                    | select(any(has("accept")) and any(.match?.left?.payload? == {"protocol":"ip","field":"saddr"}
                        and .match.right == $ip)) | $n] as $accepts
                | [{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},
                    "op":"==","right":$ip}},{"accept":null}] as $exact
                | if any($accepts[]; $rules[.] != $exact) then "invalid"
                  elif $drop != null and any($accepts[]; . >= $drop) then "late"
                  else ($accepts | length) end
            ' <<<"$out") || return 1
        else
            actual=0
            drop_seen=0
            while IFS= read -r line; do
                [[ "$line" == *" -s $subnet "* && "$line" == *" -j DROP"* ]] && drop_seen=1
                if [[ "$line" == *"$ip"* && "$line" == *" -j ACCEPT"* ]]; then
                    tor_egress_sync_iptables_accept "$line" "$ip" || return 1
                    [ "$drop_seen" = 0 ] || return 1
                    actual=$((actual + 1))
                fi
            done <<<"$out"
        fi
        expected=0
        grep -Fxq -- "$ip" <<<"$active" && expected=1
        [ "$actual" = "$expected" ] || return 1
    done
    if [ "$backend" = iptables ]; then
        while IFS= read -r ip; do [ -z "$ip" ] || sync_ips+=("$ip"); done <<<"$active"
        expected_rules=$(tor_egress_rules "$subnet" "$prefix.25" "${sync_ips[@]}")
        while IFS= read -r line; do
            [[ "$line" == *"$TOR_EGRESS_TAG"* ]] || continue
            canonical=$(tor_egress_iptables_canonical "$line") || return 1
            matched=0
            while IFS= read -r expected_line; do
                if [ "$canonical" = "$(tor_egress_iptables_canonical "-A DOCKER-USER -m comment --comment $TOR_EGRESS_TAG $expected_line")" ]; then
                    matched=1
                    break
                fi
            done <<<"$expected_rules"
            [ "$matched" = 1 ] || return 1
        done <<<"$out"
    fi
}
