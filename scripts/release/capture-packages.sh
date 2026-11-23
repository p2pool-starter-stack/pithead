#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2317

set -Eeuo pipefail

os_flavor() {
    local base
    base="$(docker image inspect "$1" --format '{{index .Config.Labels "org.opencontainers.image.base.name"}}' 2>/dev/null || true)"
    if [ -z "$base" ]; then
        base="$(docker image inspect "$1" --format '{{range .RootFS.Layers}}{{.}}{{end}}' 2>/dev/null | head -1 || true)"
    fi
    if printf '%s' "$base" | grep -qiE '^alpine'; then
        echo "alpine"
    elif printf '%s' "$base" | grep -qiE '^ubuntu'; then
        echo "ubuntu"
    elif printf '%s' "$base" | grep -qiE '^debian'; then
        echo "debian"
    fi
}

capture_from_image() {
    local img="$1" flavor="$2"
    case "$flavor" in
    alpine)
        docker run --rm --entrypoint /bin/sh "$img" -c 'apk info --installed 2>/dev/null | while IFS= read -r line; do
            name="$(printf "%s" "$line" | awk -F"-" "{print \$1}")"
            rest="$(printf "%s" "$line" | sed "s/^${name}-//")"
            version="$(printf "%s" "$rest" | sed "s/-[0-9].*//")"
            arch="$(printf "%s" "$rest" | grep -oE "[-][a-z0-9]+$" || true)"
            [ -z "$arch" ] && arch="unknown"
            printf "%s|%s|%s|%s\n" "$name" "$version" "$arch" "alpine"
        done' 2>/dev/null || return 1
        ;;
    debian | ubuntu)
        docker run --rm --entrypoint dpkg "$img" -l 2>/dev/null | awk '
            /^ii/ {
                name=$2; version=$3; arch=$4
                printf "%s|%s|%s|%s\n", name, version, arch, "'"$flavor"'"
            }' 2>/dev/null || return 1
        ;;
    *)
        return 0
        ;;
    esac
}

parse_file() {
    local path="$1" line num=0 errs=0
    [ -f "$path" ] || { echo "parse_file: $path not found" >&2; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        num=$((num + 1))
        [ -z "$line" ] && continue
        case "$line" in
            '#'*) continue ;;
        esac
        if ! printf '%s' "$line" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.+-_-]*\|[^|]+\|[a-z0-9_-]+\|(debian|ubuntu|alpine)$'; then
            echo "parse_file: bad format at line $num: $line" >&2
            errs=$((errs + 1))
        fi
    done < "$path"
    [ "$errs" -eq 0 ] || return 1
}

if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st() {
        if [ "$2" = "$3" ]; then
            echo "  self-test ok: $1"
        else
            echo "  self-test FAIL: $1 (got [$2], want [$3])"
            st_fail=1
        fi
    }
    export CAPTURE_RETRY_SLEEP=0

    docker() {
        case "$*" in
        *"inspect"*)
            local img="${3:-}"
            if printf '%s' "$img" | grep -qi alpine; then
                echo 'alpine:3.24@sha256:abc123'
            elif printf '%s' "$img" | grep -qi ubuntu; then
                echo 'ubuntu:24.04@sha256:def456'
            elif printf '%s' "$img" | grep -qi debian; then
                echo 'debian:trixie-slim@sha256:ghi789'
            else
                echo ''
            fi
            ;;
        *run*dpkg*)
            for arg in "$@"; do case "$arg" in *:*) img="$arg"; break;; esac; done
            printf 'ii  systemd                         257.9-1~deb13u1      amd64\n'
            printf 'ii  jq                              1.7.1-3+deb13u1      amd64\n'
            ;;
        *run*)
            printf 'systemd|257.9|x86_64|alpine\njq|1.7.1|x86_64|alpine\n'
            ;;
        *)
            return 1
            ;;
        esac
    }

    st "alpine image is detected" "$(os_flavor 'ghcr.io/foo/bar:latest@alpine')" "alpine"
    st "ubuntu image is detected" "$(os_flavor 'ubuntu:fake')" "ubuntu"
    st "debian image is detected" "$(os_flavor 'debian:fake')" "debian"
    st "unknown base prints empty" "$(os_flavor 'unknown:fake')" ""

    out="$(capture_from_image 'ubuntu:fake' 'ubuntu')"
    st "dpkg capture outputs two packages" "$(echo "$out" | wc -l | tr -d ' ')" "2"
    st "dpkg line format is name|version|arch|flavor" "$(printf '%s\n' "$out" | head -1)" "systemd|257.9-1~deb13u1|amd64|ubuntu"

    out="$(capture_from_image 'alpine:fake' 'alpine')"
    st "apk capture outputs two packages" "$(echo "$out" | wc -l | tr -d ' ')" "2"
    st "apk line format is name|version|arch|flavor" "$(printf '%s\n' "$out" | head -1)" "systemd|257.9|x86_64|alpine"

    out="$(capture_from_image 'unknown:fake' 'unknown')"
    st "unknown os returns empty" "$(printf '%s' "$out" | wc -l | tr -d ' ')" "0"

    _tmp="$(mktemp)"
    trap 'rm -f "$_tmp"' EXIT

    cat >"$_tmp" <<'EOF'
# comment line
systemd|257.9-1~deb13u1|amd64|debian
jq|1.7.1-3+deb13u1|amd64|debian
EOF
    st "parse_file accepts valid input rc 0" "$(parse_file "$_tmp" >/dev/null && echo 0 || echo 1)" "0"

    cat >"$_tmp" <<'EOF'
badline no pipes
EOF
    st "parse_file rejects malformed line" "$(parse_file "$_tmp" >/dev/null 2>&1 && echo 0 || echo 1)" "1"

    cat >"$_tmp" <<'EOF'
systemd|257.9|amd64|unknown_os
EOF
    st "parse_file rejects bad os_flavor" "$(parse_file "$_tmp" >/dev/null 2>&1 && echo 0 || echo 1)" "1"

    st "parse_file refuses missing file" "$(parse_file "/no/such/file" >/dev/null 2>&1 && echo 0 || echo 1)" "1"

    unset -f docker

    if [ "$st_fail" = 0 ]; then
        echo "capture-packages self-test OK"
    fi
    exit "$st_fail"
fi

if [ "${1:-}" = "--from-file" ]; then
    [ "${2:-}" ] || { echo "usage: $0 --from-file <path>" >&2; exit 1; }
    parse_file "$2"
    exit $?
fi

[ "$#" -ge 1 ] || {
    echo "usage: $0 <image-ref> [image-ref ...]" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || {
    echo "capture-packages: docker is required" >&2
    exit 1
}

failed=0
for img in "$@"; do
    flavor="$(os_flavor "$img")"
    [ -n "$flavor" ] || {
        echo "WARNING: could not determine OS flavour for $img — skipping package capture" >&2
        continue
    }
    if ! capture_from_image "$img" "$flavor"; then
        echo "ERROR: failed to capture packages from $img (flavour=$flavor)" >&2
        failed=1
    fi
done

exit "$failed"
