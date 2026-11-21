#!/usr/bin/env bash
set -euo pipefail
trap 'echo "seed script error at line $LINENO" >&2' ERR
tag="$1" action="$2"
env_value() { grep -E "^$1=" /data/pithead/.env | tail -n1 | cut -d= -f2- | tr -d "\"'"; }
tordir=$(env_value TOR_DATA_DIR)
cdir=$(env_value CADDY_LOG_DIR)
caddy_file="$cdir/access-sbproof-$tag.log"
case "$action" in
window)
    wallet="4$(printf 'B%.0s' $(seq 1 94))"
    onion="$(printf 'a%.0s' $(seq 1 56)).onion"
    torkey="sbproofkey-$tag" token="sbproof-token-$tag" login="sbproof-login-$tag" cookie="sbproof-cookie-$tag"
    printf 'CANARY %s\n' "$wallet" "$onion" "$torkey" "$token" "$login" "$cookie"
    printf 'sbproof-before-%s\n' "$tag" | systemd-cat -t sbproof
    sleep 2
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sleep 1
    printf 'sbproof-in-%s wallet %s --http-access-token %s onion %s\n' "$tag" "$wallet" "$token" "$onion" | systemd-cat -t sbproof
    podman exec tor sh -c "echo 'sbproof container --rpc-login $login' >/proc/1/fd/1"
    printf 'TorKey %s\nGuard in=sbproof bridge_addr=%s\n' "$torkey" "$torkey" >>"$tordir/state"
    printf '{"ts":%s,"request":{"uri":"/api/%s","headers":{"Cookie":["%s"],"User-Agent":["sbproof"]}},"resp_headers":{"Set-Cookie":["%s"]}}\n' \
        "$(date -u +%s)" "$token" "$cookie" "$cookie" >"$caddy_file"
    journalctl --sync
    seen=$(journalctl -t sbproof --no-pager -o cat)
    [[ "$seen" == *"$token"* ]] || {
        echo "seed check failed: journal line" >&2
        exit 11
    }
    seen=$(podman logs tor 2>&1 || true)$(journalctl --no-pager -o cat -g "$login" || true)
    [[ "$seen" == *"$login"* ]] || {
        echo "seed check failed: container log line" >&2
        exit 12
    }
    grep -qF -- "$torkey" "$tordir/state" || {
        echo "seed check failed: Tor state line" >&2
        exit 13
    }
    grep -qF -- "$cookie" "$caddy_file" || {
        echo "seed check failed: Caddy line" >&2
        exit 14
    }
    sleep 1
    until=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sleep 2
    printf 'sbproof-after-%s\n' "$tag" | systemd-cat -t sbproof
    printf 'WINDOW %s %s\n' "$since" "$until"
    ;;
cleanup)
    podman kill -s CONT tor >/dev/null 2>&1 || true
    rm -f "$caddy_file"
    if [ -f "$tordir/state" ]; then
        grep -v "sbproofkey-$tag" "$tordir/state" >"$tordir/state.sbproof" || true
        cat "$tordir/state.sbproof" >"$tordir/state"
        rm -f "$tordir/state.sbproof"
    fi
    ;;
wedge-tor) podman kill -s STOP tor ;;
release-tor)
    podman kill -s CONT tor
    for _ in $(seq 1 60); do
        podman exec tor /usr/local/bin/tor-healthcheck.sh >/dev/null 2>&1 && exit 0
        sleep 5
    done
    exit 1
    ;;
stop-monerod) systemctl stop monerod.service ;;
start-monerod) systemctl start monerod.service ;;
*) exit 2 ;;
esac
