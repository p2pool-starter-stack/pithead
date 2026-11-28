#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/watch/pin-bump.sh
source "$ROOT/scripts/watch/pin-bump.sh"

self_test() {
    local fail=0 t d out
    t="$(mktemp -d)"
    trap 'rm -rf "$t"' RETURN
    check() {
        if [ "$2" = "$3" ]; then
            echo "ok   $1"
        else
            echo "FAIL $1: got '$2', want '$3'"
            fail=1
        fi
    }
    local h_old h_new sha_old sha_new
    h_old="$(printf 'a%.0s' {1..64})"
    h_new="$(printf 'b%.0s' {1..64})"
    sha_old="$(printf '1%.0s' {1..40})"
    sha_new="$(printf '2%.0s' {1..40})"
    export PIN_BUMP_ROOT="$t"
    mkdir -p "$t/build/monero" "$t/build/p2pool" "$t/build/xmrig-proxy" "$t/os/rootfs"
    printf 'FROM x\nARG MONERO_VERSION=v0.18.5.1\nARG MONERO_HASH=%s\nRUN y\n' "$h_old" >"$t/build/monero/Dockerfile"
    printf 'FROM x\nARG P2POOL_VERSION=v4.18.1\nARG P2POOL_HASH=%s\nRUN y\n' "$h_old" >"$t/build/p2pool/Dockerfile"
    printf 'FROM x\nARG XMRIG_PROXY_VERSION=6.26.0\nARG XMRIG_PROXY_HASH=%s\nRUN y\n' "$h_old" >"$t/build/xmrig-proxy/Dockerfile"
    printf '# pins the commit of RigForge\n# v1.18.1 (11111111); pin releases by commit.\nARG RIGFORGE_REF=%s\nRUN y\n' "$sha_old" >"$t/os/rootfs/Dockerfile"
    printf 'asset-bytes' >"$t/asset"
    export PIN_BUMP_ASSET_FILE="$t/asset"
    h_new="$(sha256sum <"$t/asset" | cut -d' ' -f1)"
    rel() { printf '{"tag_name":"%s","draft":false,"prerelease":false,"assets":[{"name":"%s","digest":"%s"}]}' "$1" "$2" "$3" >"$t/release.json"; }
    export PIN_BUMP_RELEASE_JSON="$t/release.json"

    check "current version reads each pin's spelling" \
        "$(current_version monero) $(current_version p2pool) $(current_version xmrig-proxy) $(current_version rigforge)" \
        "v0.18.5.1 v4.18.1 v6.26.0 v1.18.1"
    newer_than v4.18.10 v4.18.9 && d=newer || d=not
    check "version order is numeric, not lexical" "$d" newer
    newer_than v4.18.1 v4.18.1 && d=newer || d=not
    check "an equal version is not newer" "$d" not
    newer_than v4.17.9 v4.18.1 && d=newer || d=not
    check "an older release is not newer" "$d" not
    same_minor v0.18.6.0 v0.18.5.1 && d=same || d=other
    check "a monero patch stays in the pinned minor" "$d" same
    same_minor v0.19.0.0 v0.18.5.1 && d=same || d=other
    check "a monero minor is a different minor" "$d" other

    rel v4.19.0 p2pool-v4.19.0-linux-x64.tar.gz "sha256:$h_new"
    out="$(detect p2pool)"
    check "p2pool detect reports stale with the downloaded hash" "$(printf '%s' "$out" | grep -E '^(stale|latest|pin|branch)=' | tr '\n' ' ')" \
        "stale=true latest=v4.19.0 pin=$h_new branch=bot/p2pool-v4.19.0 "
    rel v4.19.0 p2pool-v4.19.0-linux-x64.tar.gz "sha256:$h_old"
    check "a release digest that disagrees with the download is refused" "$(detect p2pool 2>/dev/null && echo accepted || echo refused)" refused
    rel v4.19.0 p2pool-v4.19.0-linux-x64.tar.gz ""
    check "a release without a digest is refused" "$(detect p2pool 2>/dev/null && echo accepted || echo refused)" refused
    check "the command line exits non-zero when detect refuses" "$(bash "$ROOT/scripts/watch/pin-bump.sh" detect p2pool >/dev/null 2>&1 && echo exit0 || echo nonzero)" nonzero
    rel v4.18.1 p2pool-v4.18.1-linux-x64.tar.gz "sha256:$h_new"
    check "an equal release is not stale" "$(detect p2pool | sed -n 's/^stale=//p')" false
    printf '{"tag_name":"v9.9.9","draft":false,"prerelease":true,"assets":[]}' >"$t/release.json"
    check "a prerelease is refused" "$(detect p2pool 2>/dev/null && echo accepted || echo refused)" refused
    printf '{"tag_name":"nightly","draft":false,"prerelease":false,"assets":[]}' >"$t/release.json"
    check "a tag that is not a version is refused" "$(detect p2pool 2>/dev/null && echo accepted || echo refused)" refused

    rel v6.27.0 xmrig-proxy-6.27.0-linux-static-x64.tar.gz "sha256:$h_new"
    out="$(detect xmrig-proxy)"
    check "xmrig-proxy detect names the tag spelling and the branch" "$(printf '%s' "$out" | grep -E '^(stale|current|latest)=' | tr '\n' ' ')" \
        "stale=true current=v6.26.0 latest=v6.27.0 "

    mrel() { jq -n --arg t "$1" --arg u "$2" '[{tag_name: $t, draft: false, prerelease: false}, {tag_name: $u, draft: false, prerelease: false}, {tag_name: "v0.18.5.1", draft: false, prerelease: false}]' >"$t/release.json"; }
    mrel v0.18.5.2 v0.18.5.0
    printf 'monero-linux-x64-v0.18.5.2.tar.bz2, %s\n' "$h_new" >"$t/hashes.txt"
    export PIN_BUMP_HASHES_FILE="$t/hashes.txt"
    out="$(detect monero)"
    check "monero patch bump is stale with the published hash" "$(printf '%s' "$out" | grep -E '^(stale|pin|held)=' | tr '\n' ' ')" "stale=true pin=$h_new held=none "
    printf 'monero-linux-x64-v0.18.5.2.tar.bz2, %s\n' "$h_old" >"$t/hashes.txt"
    check "monero refuses a download that hashes.txt contradicts" "$(detect monero 2>/dev/null && echo accepted || echo refused)" refused
    printf 'monero-linux-x64-v0.18.5.1.tar.bz2, %s\n' "$h_new" >"$t/hashes.txt"
    check "monero refuses a release hashes.txt does not list" "$(detect monero 2>/dev/null && echo accepted || echo refused)" refused
    printf 'monero-linux-x64-v0.19.0.0.tar.bz2, %s\n' "$h_new" >"$t/hashes.txt"
    mrel v0.19.0.0 v0.18.5.1
    out="$(detect monero)"
    check "a monero minor is held and the pinned minor has nothing newer" "$(printf '%s' "$out" | grep -E '^(stale|held)=' | tr '\n' ' ')" "stale=false held=minor "
    printf 'monero-linux-x64-v0.18.5.2.tar.bz2, %s\n' "$h_new" >"$t/hashes.txt"
    mrel v0.19.0.0 v0.18.5.2
    out="$(detect monero)"
    check "a monero patch in the pinned minor is still proposed after a new minor ships" "$(printf '%s' "$out" | grep -E '^(stale|latest|held)=' | tr '\n' ' ')" "stale=true latest=v0.18.5.2 held=minor "

    rel v1.18.2 "" ""
    export PIN_BUMP_COMMIT_SHA="$sha_new"
    out="$(detect rigforge)"
    check "rigforge resolves the tag to its commit" "$(printf '%s' "$out" | grep -E '^(stale|pin|branch)=' | tr '\n' ' ')" "stale=true pin=$sha_new branch=bot/rigforge-v1.18.2 "
    export PIN_BUMP_COMMIT_SHA="not-a-sha"
    check "rigforge refuses a value that is not a commit" "$(detect rigforge 2>/dev/null && echo accepted || echo refused)" refused
    export PIN_BUMP_COMMIT_SHA="$sha_old"
    check "rigforge at the pinned commit is not stale" "$(detect rigforge | sed -n 's/^stale=//p')" false
    rel v1.18.0 "" ""
    export PIN_BUMP_COMMIT_SHA="$sha_new"
    check "rigforge never moves backwards" "$(detect rigforge | sed -n 's/^stale=//p')" false

    apply_pin p2pool v4.19.0 "$h_new"
    check "apply rewrites the p2pool version and hash together" "$(cat "$t/build/p2pool/Dockerfile")" \
        "$(printf 'FROM x\nARG P2POOL_VERSION=v4.19.0\nARG P2POOL_HASH=%s\nRUN y' "$h_new")"
    apply_pin xmrig-proxy v6.27.0 "$h_new"
    check "apply writes xmrig-proxy without the v" "$(current_version xmrig-proxy)" v6.27.0
    check "xmrig-proxy file carries the bare version" "$(sed -n 's/^ARG XMRIG_PROXY_VERSION=//p' "$t/build/xmrig-proxy/Dockerfile")" 6.27.0
    apply_pin monero v0.18.5.2 "$h_new"
    check "apply rewrites the monero pair" "$(current_version monero) $(current_value monero)" "v0.18.5.2 $h_new"
    apply_pin rigforge v1.18.2 "$sha_new"
    check "apply rewrites the rigforge ref and its comment" "$(cat "$t/os/rootfs/Dockerfile")" \
        "$(printf '# pins the commit of RigForge\n# v1.18.2 (22222222); pin releases by commit.\nARG RIGFORGE_REF=%s\nRUN y' "$sha_new")"
    check "apply refuses a malformed hash" "$(apply_pin p2pool v4.20.0 abc 2>/dev/null && echo applied || echo refused)" refused
    check "apply refuses a malformed version" "$(apply_pin p2pool '1; rm' "$h_new" 2>/dev/null && echo applied || echo refused)" refused
    check "refusal leaves the pin untouched" "$(current_version p2pool)" v4.19.0

    printf '[{"number":1,"headRefName":"bot/p2pool-v4.19.0","author":{"login":"app/github-actions"}},{"number":2,"headRefName":"bot/p2pool-v4.18.9","author":{"login":"github-actions[bot]"}},{"number":3,"headRefName":"bot/monero-v0.18.5.2","author":{"login":"github-actions"}},{"number":4,"headRefName":"bot/p2pool-v1.0.0","author":{"login":"some-human"}},{"number":5,"headRefName":null,"author":{"login":"app/github-actions"}}]' >"$t/prs.json"
    check "superseded keeps the wanted head and closes older ones of the same component only" \
        "$(superseded p2pool bot/p2pool-v4.19.0 <"$t/prs.json")" $'1\tbot/p2pool-v4.19.0\tkeep\n2\tbot/p2pool-v4.18.9\tclose'
    check "superseded with no want closes every own head of the component" "$(superseded p2pool '' <"$t/prs.json" | grep -c close)" 2
    check "superseded leaves another component alone" "$(superseded monero bot/monero-v0.18.5.2 <"$t/prs.json")" $'3\tbot/monero-v0.18.5.2\tkeep'
    check "pr body has the three house sections" "$(pr_body p2pool v4.18.1 v4.19.0 | grep -c '^## ')" 3
    check "pr body for p2pool requires the advisory check" "$(pr_body p2pool v4.18.1 v4.19.0 | grep -c 'security advisories for v4.19.0')" 1
    check "pr body for monero requires the advisory check" "$(pr_body monero 0.18.4.5 0.18.4.6 | grep -c 'security advisories for 0.18.4.6')" 1
    check "pr body for rigforge omits the advisory check" "$(pr_body rigforge aaa v1 | grep -c 'security advisories')" 0
    [ "$fail" = 0 ] && echo "pin-bump self-test OK"
    return "$fail"
}

self_test
