#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${TOR_DOCKERFILE:-$ROOT/build/tor/Dockerfile}"
ALPINE_BRANCH_RE='^[0-9]+\.[0-9]+$'
VERSION_RE='^[0-9]+(\.[0-9]+)+-r[0-9]+$'

alpine_branch() {
    local branch
    branch="$(sed -nE 's/^FROM[[:space:]]+alpine:([0-9][0-9.]*)(@[^[:space:]]+)?[[:space:]]*$/\1/p' "$DOCKERFILE" | head -1)"
    [[ "$branch" =~ $ALPINE_BRANCH_RE ]] || {
        echo "no Alpine minor version tag on the FROM line of $DOCKERFILE" >&2
        return 1
    }
    printf '%s' "$branch"
}

index_url() {
    if [ -n "${TOR_APKINDEX_URL:-}" ]; then
        printf '%s' "$TOR_APKINDEX_URL"
        return
    fi
    printf 'https://dl-cdn.alpinelinux.org/alpine/v%s/community/x86_64/APKINDEX.tar.gz' "$(alpine_branch)"
}

current_pin() {
    sed -n 's/^ARG TOR_VERSION=//p' "$DOCKERFILE" | head -1
}

index_tor_version() {
    awk 'BEGIN { RS = ""; FS = "\n" }
        { pkg = ""; ver = ""
          for (i = 1; i <= NF; i++) {
              if ($i ~ /^P:/) pkg = substr($i, 3)
              if ($i ~ /^V:/) ver = substr($i, 3)
          }
          if (pkg == "tor") print ver }'
}

newer_than() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

apply_pin() {
    local version="$1" tmp
    [[ "$version" =~ $VERSION_RE ]] || {
        echo "refusing malformed version '$version'" >&2
        return 1
    }
    tmp="$(mktemp)"
    sed "s/^ARG TOR_VERSION=.*/ARG TOR_VERSION=${version}/" "$DOCKERFILE" >"$tmp"
    cat "$tmp" >"$DOCKERFILE"
    rm -f "$tmp"
    [ "$(current_pin)" = "$version" ]
}

superseded() {
    local want="${1:-}"
    jq -r --arg want "$want" '
        def trusted: ((.author.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "")) == "github-actions";
        def ours: ((.headRefName // "") | startswith("bot/tor-"));
        (map(select(trusted and ours and .headRefName == $want)) | .[0].headRefName // "") as $keep |
        map(select(trusted and ours))[] |
        [ (.number | tostring), .headRefName, (if .headRefName == $keep then "keep" else "close" end) ] | @tsv'
}

detect() {
    local current latest branch url
    current="$(current_pin)"
    [[ "$current" =~ $VERSION_RE ]] || {
        echo "no valid TOR_VERSION pin in $DOCKERFILE" >&2
        return 1
    }
    branch="$(alpine_branch)"
    url="$(index_url)"
    latest="$(curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 20000000 --retry 3 "$url" | tar -xzO APKINDEX | index_tor_version)"
    [ "$(printf '%s\n' "$latest" | wc -l | tr -d ' ')" = 1 ] && [[ "$latest" =~ $VERSION_RE ]] ||
        {
            echo "APKINDEX did not carry exactly one valid tor version: '$latest'" >&2
            return 1
        }
    if newer_than "$latest" "$current"; then
        printf 'stale=true\ncurrent=%s\nlatest=%s\nbranch=%s\n' "$current" "$latest" "$branch"
    else
        printf 'stale=false\ncurrent=%s\nlatest=%s\nbranch=%s\n' "$current" "$latest" "$branch"
    fi
}

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
    printf 'C:x\nP:tor-doc\nV:9.9.9-r0\n\nC:y\nP:tor\nV:0.4.9.18-r1\n\nC:z\nP:torsocks\nV:9.9.9-r0\n' >"$t/index"
    check "index parse picks only the tor package" "$(index_tor_version <"$t/index")" "0.4.9.18-r1"
    check "index without tor yields nothing" "$(printf 'P:tor-doc\nV:1-r0\n' | index_tor_version)" ""
    newer_than 0.4.9.18-r0 0.4.9.17-r0 && d=newer || d=not
    check "a higher version is newer" "$d" newer
    newer_than 0.4.9.9-r0 0.4.9.17-r0 && d=newer || d=not
    check "version order is numeric, not lexical" "$d" not
    newer_than 0.4.9.17-r0 0.4.9.17-r0 && d=newer || d=not
    check "an equal version is not newer" "$d" not
    newer_than 0.4.9.17-r1 0.4.9.17-r0 && d=newer || d=not
    check "a higher revision is newer" "$d" newer
    printf 'FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6\nARG TOR_VERSION=0.4.9.17-r0\nRUN x "tor=${TOR_VERSION}"\n' >"$t/Dockerfile"
    check "the Alpine branch comes from the FROM tag" "$(DOCKERFILE="$t/Dockerfile" alpine_branch)" "3.24"
    printf 'FROM alpine:9.99@sha256:abc\nARG TOR_VERSION=0.4.9.17-r0\n' >"$t/Dockerfile-99"
    check "the index URL names the pinned Alpine branch" \
        "$(DOCKERFILE="$t/Dockerfile-99" TOR_APKINDEX_URL="" index_url)" \
        "https://dl-cdn.alpinelinux.org/alpine/v9.99/community/x86_64/APKINDEX.tar.gz"
    check "TOR_APKINDEX_URL overrides the derived index URL" \
        "$(TOR_APKINDEX_URL="file:///fixture/APKINDEX.tar.gz" index_url)" "file:///fixture/APKINDEX.tar.gz"
    printf 'FROM alpine@sha256:abc\nARG TOR_VERSION=0.4.9.17-r0\n' >"$t/Dockerfile-untagged"
    check "an untagged Alpine base is refused" \
        "$(DOCKERFILE="$t/Dockerfile-untagged" alpine_branch 2>/dev/null && echo accepted || echo refused)" refused
    printf 'FROM alpine:latest\nARG TOR_VERSION=0.4.9.17-r0\n' >"$t/Dockerfile-latest"
    check "a rolling Alpine tag is refused" \
        "$(DOCKERFILE="$t/Dockerfile-latest" alpine_branch 2>/dev/null && echo accepted || echo refused)" refused
    DOCKERFILE="$t/Dockerfile"
    apply_pin 0.4.9.18-r1
    out="$(cat "$t/Dockerfile")"
    check "apply_pin rewrites only the pin line" "$out" \
        $'FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6\nARG TOR_VERSION=0.4.9.18-r1\nRUN x "tor=${TOR_VERSION}"'
    check "apply_pin refuses a malformed version" "$(apply_pin '1; rm -rf /' 2>/dev/null && echo applied || echo refused)" refused
    check "refusal leaves the file untouched" "$(current_pin)" "0.4.9.18-r1"
    printf '[{"number":1,"headRefName":"bot/tor-0.4.9.18-r1","author":{"login":"app/github-actions"}},{"number":2,"headRefName":"bot/tor-0.4.9.17-r0","author":{"login":"github-actions[bot]"}},{"number":3,"headRefName":"bot/tor-9.9.9-r0","author":{"login":"github-actions"}},{"number":4,"headRefName":"bot/tor-8.8.8-r0","author":{"login":"app/dependabot"}},{"number":5,"headRefName":"bot/tor-7.7.7-r0","author":{"login":"some-human"}},{"number":6,"headRefName":"feature/tor-idea","author":{"login":"app/github-actions"}},{"number":7,"headRefName":null,"author":{"login":"app/github-actions"}}]' >"$t/prs.json"
    check "superseded keeps only the want head across all three author shapes" \
        "$(superseded bot/tor-0.4.9.18-r1 <"$t/prs.json")" \
        $'1\tbot/tor-0.4.9.18-r1\tkeep\n2\tbot/tor-0.4.9.17-r0\tclose\n3\tbot/tor-9.9.9-r0\tclose'
    check "superseded with a want nothing serves keeps none" \
        "$(superseded bot/tor-0.4.9.99-r0 <"$t/prs.json" | grep -cF keep)" "0"
    check "superseded with no want closes every own head" \
        "$(superseded '' <"$t/prs.json" | wc -l | tr -d ' ')" "3"
    check "superseded excludes foreign authors, foreign heads and null refs" \
        "$(superseded bot/tor-0.4.9.18-r1 <"$t/prs.json" | grep -cE '^[4567]')" "0"
    check "superseded on an empty list prints nothing" \
        "$(printf '[]' | superseded bot/tor-0.4.9.18-r1 | wc -l | tr -d ' ')" "0"
    [ "$fail" = 0 ] && echo "tor-bump self-test OK"
    return "$fail"
}

case "${1:-}" in
detect) detect ;;
apply) apply_pin "${2:?usage: tor-bump.sh apply VERSION}" ;;
superseded) superseded "${2:-}" ;;
--self-test) self_test ;;
*)
    echo "usage: tor-bump.sh detect | apply VERSION | superseded [WANT] | --self-test" >&2
    exit 2
    ;;
esac
