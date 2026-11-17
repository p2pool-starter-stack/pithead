#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/support-bundle-verdict.sh
. "$HERE/support-bundle-verdict.sh"
td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT
printf 'SECRET-ONE\nSECRET-TWO\n' >"$td/canaries"
: >"$td/empty"

fixture() {
    local d="$1" rel
    mkdir -p "$d"
    for rel in $SB_PROOF_REQUIRED; do
        mkdir -p "$d/$(dirname "$rel")"
        printf 'content of %s\n' "$rel" >"$d/$rel"
    done
    printf 'line one\nsbproof-in-T\nline three\n' >"$d/journal/all.log"
    printf '{"service":"monerod","reachable":false}\n' >"$d/status/monerod.json"
    printf '%s\n' "$SB_PROOF_REQUIRED" | tr ' ' '\n' | jq -R '{path: .}' | jq -s \
        '{manifest_version: 1, files: ., failures: [{step: "tor/control.txt", status: "timeout"}, {step: "status/monerod.json", status: "failed"}]}' >"$d/manifest.json"
}

expect() {
    local rc=0
    support_bundle_verdict "$3" "$4" sbproof-in-T sbproof-before-T sbproof-after-T "${5:-$td/canaries}" >"$td/out" 2>&1 || rc=$?
    if [ "$2" = pass ] && [ "$rc" -ne 0 ]; then
        echo "FAIL: $1 was refused: $(cat "$td/out")"
        exit 1
    fi
    if [ "$2" = fail ] && [ "$rc" -eq 0 ]; then
        echo "FAIL: $1 was accepted"
        exit 1
    fi
}

fixture "$td/good"
for mode in baseline tor-wedged monerod-stopped; do expect "a complete bundle in $mode mode" pass "$td/good" "$mode"; done

fixture "$td/nomanifest"
rm "$td/nomanifest/manifest.json"
expect "a bundle without manifest.json" fail "$td/nomanifest" baseline

fixture "$td/missing"
rm "$td/missing/tor/state-guards.txt"
expect "a bundle missing a required file" fail "$td/missing" baseline

fixture "$td/emptyfile"
cp "$td/empty" "$td/emptyfile/rauc.txt"
expect "a bundle with an empty required file" fail "$td/emptyfile" baseline

fixture "$td/unlisted"
jq '.files |= map(select(.path != "host.txt"))' "$td/unlisted/manifest.json" >"$td/m" && mv "$td/m" "$td/unlisted/manifest.json"
expect "a file the manifest does not list" fail "$td/unlisted" baseline

fixture "$td/noin"
printf 'line one\n' >"$td/noin/journal/all.log"
expect "a bundle without the seeded in-window line" fail "$td/noin" baseline

fixture "$td/early"
printf 'sbproof-before-T\n' >>"$td/early/journal/all.log"
expect "a bundle with the line before the start" fail "$td/early" baseline

fixture "$td/late"
printf 'sbproof-after-T\n' >>"$td/late/logs.txt"
expect "a bundle with the line after the end in another file" fail "$td/late" baseline

fixture "$td/leak"
printf 'x SECRET-TWO y\n' >>"$td/leak/caddy/access.log"
expect "a bundle that carries a seeded secret" fail "$td/leak" baseline

expect "a run that seeded no secret" fail "$td/good" baseline "$td/empty"

fixture "$td/notor"
jq '.failures |= map(select(.step != "tor/control.txt"))' "$td/notor/manifest.json" >"$td/m" && mv "$td/m" "$td/notor/manifest.json"
expect "a wedged-Tor bundle whose manifest has no Tor failure" fail "$td/notor" tor-wedged
expect "the same bundle in baseline mode" pass "$td/notor" baseline

fixture "$td/nomonero"
jq '.failures |= map(select(.step != "status/monerod.json"))' "$td/nomonero/manifest.json" >"$td/m" && mv "$td/m" "$td/nomonero/manifest.json"
expect "a stopped-monerod bundle whose manifest has no failure" fail "$td/nomonero" monerod-stopped

fixture "$td/reachable"
printf '{"service":"monerod","reachable":true}\n' >"$td/reachable/status/monerod.json"
expect "a stopped-monerod bundle whose snapshot says reachable" fail "$td/reachable" monerod-stopped
expect "an unknown mode" fail "$td/good" bogus
echo "support bundle verdict selftest: ok"
