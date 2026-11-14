#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:?}/bake-images.XXXXXX")
trap 'rm -rf "$T"' EXIT
export PITHEAD_BUILD_IMAGE_TEST=1
source "$ROOT/os/build-image.sh"
cd "$T"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
hex64() { printf '%s' "$1" | awk '{ s=""; for (i = 0; i < 64; i++) s = s $0; print s }'; }
registry=registry.example/fixture
mkdir -p os/build/stage os/rootfs/images lib/pithead
cp "$ROOT/lib/pithead/03-release-verify.sh" lib/pithead/
printf 'fixture key\n' >cosign.pub
write_compose() {
    local n=1 svc
    {
        for svc in tor monero p2pool xmrig-proxy dashboard; do
            # shellcheck disable=SC2016
            printf '    image: ${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-%s:${STACK_VERSION:-dev}@sha256:%s\n' \
                "$svc" "$(hex64 "$n")"
            n=$((n + 1))
        done
        printf '    image: tecnativa/docker-socket-proxy:v0.5.0@sha256:%s\n' "$(hex64 a)"
        printf '    image: tecnativa/docker-socket-proxy:v0.5.0@sha256:%s\n' "$(hex64 a)"
        printf '    image: caddy:2.11.7@sha256:%s\n' "$(hex64 b)"
        printf '    image: ghcr.io/tari-project/minotari_node:v6@sha256:%s\n' "$(hex64 c)"
    } >os/build/stage/docker-compose.yml
}
write_compose
: >calls
docker() {
    echo "$*" >>calls
    case "$1" in
    pull | tag) return 0 ;;
    save) printf 'archive-of-%s' "$2" ;;
    run) return "${FAKE_COSIGN_RC:-0}" ;;
    *) return 1 ;;
    esac
}

bake_service_images os/build/stage/docker-compose.yml "$registry" v9 >/dev/null || fail 'bake refused a complete compose'
actual=$(find os/rootfs/images -type f -exec basename {} \; | sort | tr '\n' ' ')
[ "$actual" = "caddy.tar.gz docker-socket-proxy.tar.gz monero.tar.gz p2pool.tar.gz tor.tar.gz xmrig-proxy.tar.gz " ] || fail "archives are: $actual"
grep -qxF "pull -q $registry/pithead-tor:v9@sha256:$(hex64 1)" calls || fail 'tor not pulled by its pinned digest'
grep -qxF "pull -q caddy:2.11.7@sha256:$(hex64 b)" calls || fail 'caddy not pulled by its pinned digest'
grep -qxF "pull -q tecnativa/docker-socket-proxy:v0.5.0@sha256:$(hex64 a)" calls || fail 'socket proxy not pulled by its pinned digest'
grep -qxF "tag $registry/pithead-monero:v9@sha256:$(hex64 2) $registry/pithead-monero:v9" calls || fail 'monero not tagged for the loader'
[ "$(gzip -dc os/rootfs/images/caddy.tar.gz)" = 'archive-of-caddy:2.11.7' ] || fail 'caddy archive holds another image'
if grep -q 'tari\|dashboard' calls; then fail 'bake touched the opt-in Tari image or the wizard image'; fi
[ "$(grep -c '^run ' calls)" = 4 ] || fail 'each first-party image is cosign-verified exactly once'
grep -q "^run .* verify --key cosign.pub --private-infrastructure $registry/pithead-p2pool:v9@sha256:$(hex64 3)\$" calls || fail 'verify is not bound to the pinned digest'

rm -f os/rootfs/images/*
: >calls
FAKE_COSIGN_RC=1 bake_service_images os/build/stage/docker-compose.yml "$registry" v9 >/dev/null 2>"$T/err" && fail 'a failed signature was baked'
grep -q 'signature verification FAILED' "$T/err" || fail 'a failed signature is not named'
[ -z "$(find os/rootfs/images -type f)" ] || fail 'an unverified image was archived'

: >calls
TEST_REGISTRY=insecure.example:5000 bake_service_images os/build/stage/docker-compose.yml "$registry" v9 >/dev/null || fail 'debug registry bake refused'
if grep -q '^run ' calls; then fail 'a debug registry build ran the release verifier'; fi

sed -i.bak '/pithead-xmrig-proxy/d' os/build/stage/docker-compose.yml
bake_service_images os/build/stage/docker-compose.yml "$registry" v9 >/dev/null 2>"$T/err" && fail 'an unpinned service was baked'
grep -q 'pithead-xmrig-proxy is not digest-pinned' "$T/err" || fail 'the unpinned service is not named'

write_compose
sed -i.bak '/caddy:/d' os/build/stage/docker-compose.yml
bake_service_images os/build/stage/docker-compose.yml "$registry" v9 >/dev/null 2>"$T/err" && fail 'a compose without caddy was baked'
grep -q 'expected the caddy and docker-socket-proxy pins' "$T/err" || fail 'the missing caddy pin is not named'
echo 'selftest-bake-images: PASS'
