#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${TOR_DOCKERFILE:-$ROOT/build/tor/Dockerfile}"
INDEX_URL="${TOR_APKINDEX_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.24/community/x86_64/APKINDEX.tar.gz}"
VERSION_RE='^[0-9]+(\.[0-9]+)+-r[0-9]+$'

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

detect() {
    local current latest
    current="$(current_pin)"
    [[ "$current" =~ $VERSION_RE ]] || {
        echo "no valid TOR_VERSION pin in $DOCKERFILE" >&2
        return 1
    }
    latest="$(curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 20000000 --retry 3 "$INDEX_URL" | tar -xzO APKINDEX | index_tor_version)"
    [ "$(printf '%s\n' "$latest" | wc -l | tr -d ' ')" = 1 ] && [[ "$latest" =~ $VERSION_RE ]] ||
        {
            echo "APKINDEX did not carry exactly one valid tor version: '$latest'" >&2
            return 1
        }
    if newer_than "$latest" "$current"; then
        printf 'stale=true\ncurrent=%s\nlatest=%s\n' "$current" "$latest"
    else
        printf 'stale=false\ncurrent=%s\nlatest=%s\n' "$current" "$latest"
    fi
}

self_test() {
    local fail=0 t d out
    t="$(mktemp -d)"
    trap 'rm -rf "$t"' RETURN
    check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else
        echo "FAIL $1: got '$2', want '$3'"
        fail=1
    fi; }
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
    # shellcheck disable=SC2016
    printf 'FROM alpine\nARG TOR_VERSION=0.4.9.17-r0\nRUN x "tor=${TOR_VERSION}"\n' >"$t/Dockerfile"
    DOCKERFILE="$t/Dockerfile"
    apply_pin 0.4.9.18-r1
    out="$(cat "$t/Dockerfile")"
    check "apply_pin rewrites only the pin line" "$out" $'FROM alpine\nARG TOR_VERSION=0.4.9.18-r1\nRUN x "tor=${TOR_VERSION}"'
    check "apply_pin refuses a malformed version" "$(apply_pin '1; rm -rf /' 2>/dev/null && echo applied || echo refused)" refused
    check "refusal leaves the file untouched" "$(current_pin)" "0.4.9.18-r1"
    [ "$fail" = 0 ] && echo "tor-bump self-test OK"
    return "$fail"
}

case "${1:-}" in
detect) detect ;;
apply) apply_pin "${2:?usage: tor-bump.sh apply VERSION}" ;;
--self-test) self_test ;;
*)
    echo "usage: tor-bump.sh detect | apply VERSION | --self-test" >&2
    exit 2
    ;;
esac
