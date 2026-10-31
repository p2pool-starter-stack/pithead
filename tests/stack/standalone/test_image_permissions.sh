#!/usr/bin/env bash
set -euo pipefail
echo "== non-root image access from a restrictive checkout =="
service=${1:?service required}
image=${2:?isolated image tag required}
case "$service" in
tor | monero | p2pool | xmrig-proxy) context="build/$service" ;;
dashboard) context=dashboard ;;
*)
    echo "Unknown image service: $service" >&2
    exit 2
    ;;
esac
root=$(git rev-parse --show-toplevel)
ref=$(git rev-parse "${3:-HEAD}^{commit}")
fixture=$(mktemp -d "${TMPDIR:?}/pithead-image-permissions.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
(
    umask 077
    git clone --quiet --shared --no-checkout "$root" "$fixture/checkout"
    git -C "$fixture/checkout" -c advice.detachedHead=false checkout --quiet --detach "$ref"
)
mode=$(stat -c %a "$fixture/checkout/$context/entrypoint.sh")
[ "$mode" = 600 ] || [ "$mode" = 700 ]
if [ "$service" = tor ]; then
    test "$(stat -c %a "$fixture/checkout/$context/torrc.template")" = 600
fi
printf 'Restrictive checkout: service=%s source=%s umask=077\n' "$service" "$ref"
docker build -t "$image" "$fixture/checkout/$context"
if ! docker run --rm --network none --entrypoint sh "$image" -eu -c '
    [ "$(id -u)" != 0 ]
    readable() {
        test -r "$1" || { echo "FAIL: unreadable runtime file: $1" >&2; exit 1; }
    }
    case "$1" in
    tor)
        readable /etc/tor/torrc.template
        set -- /usr/local/bin/tor-entrypoint.sh /usr/local/bin/tor-healthcheck.sh \
            /usr/local/bin/tor-control-signal.sh /usr/local/bin/tor-recovery-diagnose.sh
        ;;
    monero)
        set -- /usr/local/bin/entrypoint.sh /usr/local/bin/monerod-healthcheck.sh \
            /usr/local/bin/wallet-entrypoint.sh /usr/local/bin/wallet-healthcheck.sh \
            /usr/local/bin/monerod-peers.sh
        ;;
    p2pool) set -- /usr/local/bin/entrypoint.sh /usr/local/bin/p2pool-healthcheck.sh ;;
    xmrig-proxy) set -- /usr/local/bin/entrypoint.sh /usr/local/bin/xmrig-proxy-healthcheck.sh ;;
    dashboard)
        inaccessible=$(find /app/mining_dashboard -type f ! -readable -print -o -type d ! -executable -print)
        test -z "$inaccessible"
        /app/.venv/bin/python -c "import mining_dashboard"
        set -- /app/entrypoint.sh /app/healthcheck.sh
        ;;
    esac
    for file do
        readable "$file"
        test -x "$file"
    done
' sh "$service"; then
    echo "FAIL: $service runtime file permissions" >&2
    exit 1
fi
echo "PASS: $service runtime file permissions"
