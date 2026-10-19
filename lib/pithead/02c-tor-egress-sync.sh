# Host-owned clearnet sync transition: claim the marker, close and verify the firewall,
# then attest the restarted daemon on Tor. Sourced after 02b by the generated CLI.
# A host request closes its chain's exemption even when a malformed marker cannot be claimed. The
# readback uses the same desired-rule predicate as apply/doctor (#2059/#2678).
egress_sync_refresh() { # <monero|tari>
    case "$1" in monero | tari) ;; *) return 1 ;; esac
    mutation_lock_acquire egress-sync
    # shellcheck disable=SC2034  # read dynamically by tor_egress_sync_ips in the preceding slice
    local rc=0 EGRESS_SYNC_CLOSE_CHAIN="$1"
    egress_sync_refresh_locked "$1" || rc=$?
    mutation_lock_release
    return "$rc"
}

egress_sync_refresh_locked() { # <monero|tari>; called with the mutation lock held
    local chain="$1" enabled rc=0 claim_failed=0 prefix ip out
    egress_sync_claim_marker "$chain" || claim_failed=1
    apply_tor_egress_firewall refresh || return 1
    enabled=$(env_get TOR_EGRESS_FIREWALL 2>/dev/null)
    if [ "$(normalize_bool "${enabled:-true}")" = true ]; then
        tor_egress_enforced || rc=$?
        [ "$rc" -eq 0 ] || return 1
        [ "$claim_failed" -eq 0 ] || return 1
        egress_sync_record_tor "$chain"
        return $?
    fi
    # An explicit firewall opt-out has no chain exemption to remove, but the old tagged rules
    # must actually be gone before the supervisor may call this transition complete.
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$prefix" ] || prefix=172.28.0
    case "$chain" in monero) ip="$prefix.26" ;; tari) ip="$prefix.27" ;; esac
    if [ "$(container_engine)" = podman ]; then
        out=$(sudo -n nft -j list table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null) || {
            sudo -n nft list tables >/dev/null 2>&1 || return 1
            [ "$claim_failed" -eq 0 ] || return 1
            egress_sync_record_tor "$chain"
            return $?
        }
        jq -e --arg ip "$ip" '[.nftables[] | select(.rule?.chain == "forward") | .rule.expr[]
            | select(.match?.left?.payload? == {"protocol":"ip","field":"saddr"})
            | select(.match.right == $ip)] | length == 0' <<<"$out" >/dev/null || return 1
    else
        out=$(sudo -n iptables -S DOCKER-USER 2>/dev/null) || {
            sudo -n iptables -S >/dev/null 2>&1 || return 1
            [ "$claim_failed" -eq 0 ] || return 1
            egress_sync_record_tor "$chain"
            return $?
        }
        grep -E -- "-s $ip(/32)?( |$)" <<<"$out" | grep -qE -- ' -j ACCEPT($| )' && return 1
    fi
    [ "$claim_failed" -eq 0 ] || return 1
    egress_sync_record_tor "$chain"
}

egress_sync_container() { # <monero|tari>
    case "$1" in
    monero) echo monerod ;;
    tari) echo tari ;;
    *) return 1 ;;
    esac
}

egress_sync_runtime_on_tor() { # <monero|tari>; docker exec succeeds only for a running daemon
    local prefix runtime tor
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null) || return 1
    [ -n "$prefix" ] || return 1
    tor="$prefix.25:9050"
    case "$1" in
    monero)
        runtime=$(docker exec monerod cat /home/ubuntu/.bitmonero/bitmonero.conf) || return 1
        awk -v expected="proxy=$tor" '/^proxy=/ { found++; if ($0 != expected) bad=1 }
            END { exit !(found == 1 && !bad) }' <<<"$runtime"
        ;;
    tari)
        runtime=$(docker exec tari cat /tmp/tari-runtime-config.toml) || return 1
        awk -v expected="\"/ip4/$prefix.25/tcp/9050\"" '
            /^\[[^]]+\][[:space:]]*$/ { section=$0; next }
            section == "[base_node.p2p.transport]" && /^[[:space:]]*type[[:space:]]*=/ {
                types++; value=$0; sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]*(#.*)?$/, "", value)
                if (value != "\"socks5\"") bad=1
            }
            section == "[base_node.p2p.transport.socks]" && /^[[:space:]]*proxy_address[[:space:]]*=/ {
                proxies++; value=$0; sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]*(#.*)?$/, "", value)
                if (value != expected) bad=1
            }
            END { exit !(types == 1 && proxies == 1 && !bad) }' <<<"$runtime"
        ;;
    *) return 1 ;;
    esac
}

egress_sync_marker_result() { # <marker-file>; safely read one regular UUID marker and its identity
    # O_NOFOLLOW + fstat pin one regular inode from the dashboard-writable directory. Never copy
    # arbitrary host file bytes into the dashboard-readable result through a marker symlink.
    python3 - "$1" <<'PY'
import json, os, re, stat, sys, uuid
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
try:
    st = os.fstat(fd)
    data = os.read(fd, 128)
    if not stat.S_ISREG(st.st_mode) or st.st_size != len(data):
        raise ValueError("invalid transition marker")
    legacy = data in (
        b"clearnet initial sync complete; node returned to Tor (#234)\n",
        b"clearnet initial sync complete; Tor transition pending (#2678)\n",
    )
    if not legacy and not re.fullmatch(
        rb"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\n", data
    ):
        raise ValueError("invalid transition marker")
    print(json.dumps({"status": "verified", "marker": str(uuid.uuid4()) if legacy else data.decode().strip(),
                      "inode": st.st_ino, "ctime_ns": st.st_ctime_ns, "uid": st.st_uid,
                      "writable": bool(st.st_mode & 0o022), "legacy": legacy}))
finally:
    os.close(fd)
PY
}

# Replace the dashboard's marker atomically with a root-owned one under a sticky directory. After
# this first host claim, neither the dashboard nor another unprivileged process can reopen clearnet
# by deleting the marker. A flag-off apply is the only re-arm path.
egress_sync_claim_marker() { # <monero|tari>
    local file dir marker result tmp
    dir=$(clearnet_state_dir)
    file="$dir/$1.synced"
    result=$(egress_sync_marker_result "$file") || return 1
    sudo chown root:root "$dir" && sudo chmod 1777 "$dir" || return 1
    marker=$(jq -r .marker <<<"$result") || return 1
    if [ "$(jq -r .uid <<<"$result")" != 0 ] || [ "$(jq -r .writable <<<"$result")" != false ] ||
        [ "$(jq -r .legacy <<<"$result")" != false ]; then
        tmp=$(sudo mktemp "$dir/.claimed.XXXXXXXX") || return 1
        if ! printf '%s\n' "$marker" | sudo tee "$tmp" >/dev/null || ! sudo chmod 644 "$tmp" ||
            ! sudo python3 -c 'import os,sys; os.replace(sys.argv[1],sys.argv[2])' "$tmp" "$file"; then
            sudo rm -f "$tmp"
            return 1
        fi
    fi
    result=$(egress_sync_marker_result "$file") || return 1
    [ "$(jq -r .marker <<<"$result")" = "$marker" ] &&
        [ "$(jq -r .uid <<<"$result")" = 0 ] &&
        [ "$(jq -r .writable <<<"$result")" = false ] &&
        [ "$(jq -r .legacy <<<"$result")" = false ]
}

# The result directory is host-owned and dashboard-mounted read-only. A stale result is rejected
# by comparing its marker inode and ctime with the current transition.
egress_sync_record_tor() { # <monero|tari>
    local cdir result started baseline container baseline_file
    result=$(egress_sync_marker_result "$(clearnet_state_dir)/$1.synced" | jq -c 'del(.uid,.writable,.legacy)') || return 1
    cdir=$(env_get CONTROL_DIR 2>/dev/null)
    [ -n "$cdir" ] || cdir="$PWD/data/control"
    container=$(egress_sync_container "$1") || return 1
    started=$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null) || return 1
    [ -n "$started" ] || return 1
    baseline_file="$cdir/results/clearnet-$1-baseline.json"
    baseline=$(jq -c --arg started "$started" '. + {started_at:$started}' <<<"$result") || return 1
    if ! jq -e --argjson marker "$result" '.marker == $marker.marker and .inode == $marker.inode and .ctime_ns == $marker.ctime_ns and (.started_at | type == "string")' "$baseline_file" >/dev/null 2>&1; then
        control_write_result "$cdir/results" "clearnet-$1-baseline" "$baseline"
        return $?
    fi
    [ "$started" != "$(jq -r .started_at "$baseline_file")" ] || return 0
    egress_sync_runtime_on_tor "$1" || return 1
    control_write_result "$cdir/results" "clearnet-$1-tor" "$result"
}
