#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APT="$ROOT/scripts/release/apt.sh"
STATE=/var/lib/pithead
LOG=/var/log/pithead-stub.log
PASS=0
FAIL=0
ok() {
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
}
check() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}
refuse() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi
}

[ "$(id -u)" = 0 ] || {
    echo "run as root on a disposable host" >&2
    exit 2
}
for tool in dpkg-deb apt-ftparchive gpg apt-get; do
    command -v "$tool" >/dev/null || {
        echo "$tool is required" >&2
        exit 2
    }
done
[ ! -e "$STATE" ] || {
    echo "$STATE exists: run on a clean host" >&2
    exit 2
}

WORK=$(mktemp -d)
chmod 755 "$WORK"
DOCKER_PATH=$(command -v docker || echo /usr/bin/docker)
stub_docker() {
    if [ -e "$DOCKER_PATH" ] && [ ! -e "$DOCKER_PATH.real" ]; then mv "$DOCKER_PATH" "$DOCKER_PATH.real"; fi
    printf '#!/bin/sh\n%s\n' "$1" >"$DOCKER_PATH"
    chmod 755 "$DOCKER_PATH"
}
restore_docker() {
    rm -f "$DOCKER_PATH"
    if [ -e "$DOCKER_PATH.real" ]; then mv "$DOCKER_PATH.real" "$DOCKER_PATH"; fi
}
trap 'restore_docker; rm -rf "$WORK"' EXIT

make_bundle() {
    local version=$1 extra=$2 dir="$WORK/b$1/pithead"
    mkdir -p "$dir/build/tor" "$dir/docs"
    printf '%s\n' "$version" >"$dir/VERSION"
    : >"$dir/docker-compose.yml"
    printf 'tor\n' >"$dir/build/tor/torrc.template"
    printf '%s\n' "$extra" >"$dir/docs/$extra"
    cat >"$dir/pithead" <<'STUB'
#!/bin/sh
echo "$1|${PITHEAD_APT_POSTINST:-}|$(pwd)" >>/var/log/pithead-stub.log
[ "$1" != upgrade ] || [ ! -e /var/lib/pithead/.fail-upgrade ] || exit 1
exit 0
STUB
    chmod 755 "$dir/pithead"
    tar -czf "$WORK/bundle-$version.tar.gz" -C "$WORK/b$version" pithead
    bash "$APT" deb "$WORK/bundle-$version.tar.gz" "$version" "$WORK/pithead_${version}_amd64.deb"
}

echo "== build =="
make_bundle 1.0.0 old.md
make_bundle 1.0.1 new.md
make_bundle 1.0.2 newer.md
V1=$WORK/pithead_1.0.0_amd64.deb
V2=$WORK/pithead_1.0.1_amd64.deb
V3=$WORK/pithead_1.0.2_amd64.deb
[ "$(dpkg-deb -f "$V1" Version)" = 1.0.0 ] && ok "package version matches the bundle" || bad "package version matches the bundle"
[ "$(dpkg-deb -f "$V1" Architecture)" = amd64 ] && ok "package is amd64" || bad "package is amd64"
refuse "a prerelease version is refused" bash "$APT" deb "$WORK/bundle-1.0.0.tar.gz" 1.0.0-rc.1 "$WORK/x.deb"
refuse "a version that differs from the bundle is refused" bash "$APT" deb "$WORK/bundle-1.0.0.tar.gz" 1.0.9 "$WORK/x.deb"

echo "== install =="
: >"$LOG"
check "apt installs the package" apt-get install -y "$V1"
check "the wrapper is on PATH" test -x /usr/bin/pithead
check "the package marker is in the working tree" test -f "$STATE/PITHEAD_PACKAGE"
check "the program tree is synced" test -f "$STATE/build/tor/torrc.template"
[ ! -s "$LOG" ] && ok "a host that was never set up gets no stack move" || bad "a host that was never set up gets no stack move"

echo "== upgrade =="
stub_docker 'echo running'
printf 'DEPLOYMENT_COMPLETED=true\n' >"$STATE/.env"
printf '{}\n' >"$STATE/config.json"
mkdir -p "$STATE/data/chain"
printf 'block\n' >"$STATE/data/chain/blk"
check "apt upgrades the package" apt-get install -y "$V2"
grep -qx "upgrade|1|$STATE" "$LOG" && ok "postinst moves the running stack once, with the package marker env" || bad "postinst moves the running stack once, with the package marker env"
check "a new shipped file arrives" test -f "$STATE/docs/new.md"
refuse "a file the release dropped is removed" test -e "$STATE/docs/old.md"
check "configuration survives" test -f "$STATE/config.json"
check "chain data survives" test -f "$STATE/data/chain/blk"

echo "== failed stack move =="
touch "$STATE/.fail-upgrade"
refuse "a failing stack move fails the upgrade" apt-get install -y "$V3"
dpkg -s pithead 2>/dev/null | grep -qE '^Status: .*(half-configured|unpacked)' && ok "dpkg reports the package as not fully configured" || bad "dpkg reports the package as not fully configured"
rm -f "$STATE/.fail-upgrade"
check "dpkg --configure -a retries the move" dpkg --configure -a
dpkg -s pithead 2>/dev/null | grep -q '^Status: install ok installed' && ok "the package is configured after the retry" || bad "the package is configured after the retry"

echo "== reconfigure =="
: >"$LOG"
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure pithead >/dev/null 2>&1
grep -qx "upgrade|1|$STATE" "$LOG" && ok "dpkg-reconfigure moves the stack again" || bad "dpkg-reconfigure moves the stack again"
stub_docker ':'
: >"$LOG"
check "dpkg-reconfigure succeeds when no stack is running" env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure pithead
[ ! -s "$LOG" ] && ok "a stopped stack is not started by the package" || bad "a stopped stack is not started by the package"

echo "== remove =="
: >"$LOG"
check "apt removes the package" apt-get remove -y pithead
grep -q '^down|' "$LOG" && ok "remove stops the stack" || bad "remove stops the stack"
refuse "the program tree is gone" test -e /usr/share/pithead
refuse "the wrapper is gone" test -e /usr/bin/pithead
restore_docker
check "configuration survives remove" test -f "$STATE/config.json"
check "chain data survives remove" test -f "$STATE/data/chain/blk"

echo "== purge =="
check "apt purges the package" apt-get purge -y pithead
refuse "the synced program is removed" test -e "$STATE/pithead"
check "configuration survives purge" test -f "$STATE/config.json"
check "the environment file survives purge" test -f "$STATE/.env"
check "chain data survives purge" test -f "$STATE/data/chain/blk"

echo "== real CLI =="
[ -x "$ROOT/pithead" ] || bash "$ROOT/scripts/build-pithead.sh" >/dev/null 2>&1
make_bundle 1.0.3 real.md
cp "$ROOT/pithead" "$WORK/b1.0.3/pithead/pithead"
tar -czf "$WORK/bundle-1.0.3.tar.gz" -C "$WORK/b1.0.3" pithead
bash "$APT" deb "$WORK/bundle-1.0.3.tar.gz" 1.0.3 "$WORK/real_1.0.3_amd64.deb"
check "the real CLI installs" apt-get install -y "$WORK/real_1.0.3_amd64.deb"
printf 'DEPLOYMENT_COMPLETED=true\n' >"$STATE/.env"
out=$(/usr/bin/pithead upgrade 2>&1)
rc=$?
[ "$rc" -ne 0 ] && grep -q "sudo apt update && sudo apt upgrade" <<<"$out" && ok "pithead upgrade refuses and names the apt command" || bad "pithead upgrade refuses and names the apt command"
check "the real CLI is purged" apt-get purge -y pithead

echo "== signed feed =="
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key "Pithead Test <test@example.invalid>" rsa3072 sign never >/dev/null 2>&1
FPR=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
gpg --batch --armor --export "$FPR" >"$WORK/pinned.asc"
bash "$APT" feed "$V3" "$WORK/feed" "$FPR"
check "the feed verifies against the pinned key" bash "$APT" verify "$WORK/feed" "$WORK/pinned.asc" "$FPR"
refuse "a different pinned fingerprint is refused" bash "$APT" verify "$WORK/feed" "$WORK/pinned.asc" 0000000000000000000000000000000000000000

apt_probe() {
    local feed=$1 key=$2 dl=$3 state="$WORK/aptstate"
    rm -rf "$state" "$dl"
    mkdir -p "$state/lists/partial" "$dl"
    chmod -R a+rX "$feed" "$key"
    printf 'deb [signed-by=%s] file:%s ./\n' "$key" "$feed" >"$state/sources.list"
    local opts=(-o "Dir::Etc::sourcelist=$state/sources.list" -o Dir::Etc::sourceparts=- -o "Dir::State::lists=$state/lists")
    apt-get "${opts[@]}" update >/dev/null 2>&1 || return 1
    (cd "$dl" && apt-get "${opts[@]}" download pithead >/dev/null 2>&1)
}
check "apt updates and downloads from the signed feed" apt_probe "$WORK/feed" "$WORK/pinned.asc" "$WORK/dl"
cmp -s "$WORK"/dl/pithead_1.0.2_amd64.deb "$V3" && ok "the served package is the built package" || bad "the served package is the built package"

cp -a "$WORK/feed" "$WORK/feed-tampered-index"
sed -i 's/^Origin: pithead$/Origin: pitheax/' "$WORK/feed-tampered-index/Release" "$WORK/feed-tampered-index/InRelease"
refuse "apt refuses a tampered Release" apt_probe "$WORK/feed-tampered-index" "$WORK/pinned.asc" "$WORK/dl2"
refuse "verify refuses a tampered Release" bash "$APT" verify "$WORK/feed-tampered-index" "$WORK/pinned.asc" "$FPR"

cp -a "$WORK/feed" "$WORK/feed-tampered-deb"
printf 'x' >>"$WORK/feed-tampered-deb/pithead_1.0.2_amd64.deb"
refuse "apt refuses a tampered package" apt_probe "$WORK/feed-tampered-deb" "$WORK/pinned.asc" "$WORK/dl3"

echo
echo "deb lifecycle: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
