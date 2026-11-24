#!/usr/bin/env bash

set -Eeuo pipefail

os_release_value() {
    sed -n "s/^$1=//p" "$2" | head -1 | tr -d '"'"'"
}

osv_ecosystem() {
    local id version_id version
    id="$(os_release_value ID "$1")"
    version_id="$(os_release_value VERSION_ID "$1")"
    version="$(os_release_value VERSION "$1")"
    [ -n "$version_id" ] || {
        echo "capture-packages: no VERSION_ID in os-release" >&2
        return 1
    }
    case "$id" in
    debian) echo "Debian:${version_id%%.*}" ;;
    ubuntu)
        case "$version" in
        *LTS*) echo "Ubuntu:$version_id:LTS" ;;
        *) echo "Ubuntu:$version_id" ;;
        esac
        ;;
    alpine) echo "Alpine:v$(printf '%s' "$version_id" | cut -d. -f1-2)" ;;
    *)
        echo "capture-packages: unsupported OS '$id'" >&2
        return 1
        ;;
    esac
}

dpkg_source_packages() {
    awk 'BEGIN { RS = ""; FS = "\n" }
    {
        pkg = ver = src = ""; installed = 0
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /) pkg = substr($i, 10)
            else if ($i ~ /^Status: .* installed$/) installed = 1
            else if ($i ~ /^Version: /) ver = substr($i, 10)
            else if ($i ~ /^Source: /) src = substr($i, 9)
        }
        if (!installed || pkg == "" || ver == "") next
        srcver = ver
        if (src == "") src = pkg
        else if (match(src, / \(.*\)$/)) { srcver = substr(src, RSTART + 2, RLENGTH - 3); src = substr(src, 1, RSTART - 1) }
        print src, srcver
    }' "$1"
}

apk_source_packages() {
    awk 'BEGIN { RS = ""; FS = "\n" }
    {
        pkg = ver = origin = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^P:/) pkg = substr($i, 3)
            else if ($i ~ /^V:/) ver = substr($i, 3)
            else if ($i ~ /^o:/) origin = substr($i, 3)
        }
        if (pkg == "" || ver == "") next
        print (origin == "" ? pkg : origin), ver
    }' "$1"
}

list_packages() {
    local dir="$1" ecosystem lines
    ecosystem="$(osv_ecosystem "$dir/os-release")" || return 1
    if [ -s "$dir/dpkg-status" ]; then
        lines="$(dpkg_source_packages "$dir/dpkg-status")"
    elif [ -s "$dir/apk-installed" ]; then
        lines="$(apk_source_packages "$dir/apk-installed")"
    else
        echo "capture-packages: no dpkg or apk database found" >&2
        return 1
    fi
    [ -n "$lines" ] || {
        echo "capture-packages: package database lists no installed packages" >&2
        return 1
    }
    [[ "$ecosystem" =~ ^[A-Za-z0-9:._-]+$ ]] || {
        echo "capture-packages: refusing ecosystem '$ecosystem'" >&2
        return 1
    }
    printf '%s\n' "$lines" | sort -u | awk -v prefix="$ecosystem" '{ print prefix, $0 }'
}

capture_image() {
    local label="$1" ref="$2" dir cid rc=0
    dir="$(mktemp -d)"
    cid="$(docker create --platform linux/amd64 "$ref" true)" || {
        rm -rf "$dir"
        return 1
    }
    docker cp -L "$cid:/etc/os-release" "$dir/os-release" >/dev/null || rc=1
    if [ "$rc" -eq 0 ] && ! docker cp -L "$cid:/var/lib/dpkg/status" "$dir/dpkg-status" >/dev/null 2>&1; then
        docker cp -L "$cid:/lib/apk/db/installed" "$dir/apk-installed" >/dev/null || rc=1
    fi
    docker rm "$cid" >/dev/null || true
    if [ "$rc" -eq 0 ]; then
        list_packages "$dir" | awk -v prefix="$label" '{ print prefix, $0 }' || rc=1
    fi
    rm -rf "$dir"
    return "$rc"
}

self_test() {
    local t fail=0 out
    t="$(mktemp -d)"
    trap 'rm -rf "$t"' RETURN
    st() {
        if [ "$2" = "$3" ]; then
            echo "  ok: $1"
        else
            printf '  FAIL: %s\n    got:  %s\n    want: %s\n' "$1" "$2" "$3"
            fail=1
        fi
    }

    printf 'ID=debian\nVERSION_ID="13"\nVERSION="13 (trixie)"\n' >"$t/debian"
    printf 'NAME="Ubuntu"\nVERSION="24.04.3 LTS (Noble Numbat)"\nID=ubuntu\nVERSION_ID="24.04"\n' >"$t/ubuntu"
    printf 'NAME="Ubuntu"\nVERSION="24.10 (Oracular Oriole)"\nID=ubuntu\nVERSION_ID="24.10"\n' >"$t/ubuntu-interim"
    printf 'ID=alpine\nVERSION_ID=3.24.1\n' >"$t/alpine"
    printf 'ID=debian\nPRETTY_NAME="Debian sid"\n' >"$t/sid"
    printf 'ID=fedora\nVERSION_ID=42\n' >"$t/fedora"
    st "Debian maps to Debian:<major>" "$(osv_ecosystem "$t/debian")" "Debian:13"
    st "Ubuntu LTS carries the :LTS suffix" "$(osv_ecosystem "$t/ubuntu")" "Ubuntu:24.04:LTS"
    st "Ubuntu interim has no suffix" "$(osv_ecosystem "$t/ubuntu-interim")" "Ubuntu:24.10"
    st "Alpine maps to Alpine:v<major.minor>" "$(osv_ecosystem "$t/alpine")" "Alpine:v3.24"
    printf 'ID=alpine\nVERSION_ID=3.24\n' >"$t/alpine-short"
    st "a two-part Alpine VERSION_ID keeps both parts" "$(osv_ecosystem "$t/alpine-short")" "Alpine:v3.24"
    st "a release without VERSION_ID is refused" "$(osv_ecosystem "$t/sid" 2>/dev/null && echo ok || echo refused)" "refused"
    printf 'ID=debian\nVERSION_ID="1/;e id;s/^/"\n' >"$t/hostile"
    mkdir -p "$t/hostile-root"
    cp "$t/hostile" "$t/hostile-root/os-release"
    printf 'Package: a\nStatus: install ok installed\nVersion: 1\n' >"$t/hostile-root/dpkg-status"
    st "a VERSION_ID outside the ecosystem alphabet is refused" "$(list_packages "$t/hostile-root" 2>/dev/null && echo ok || echo refused)" "refused"
    st "an unsupported OS is refused" "$(osv_ecosystem "$t/fedora" 2>/dev/null && echo ok || echo refused)" "refused"

    mkdir -p "$t/deb"
    cp "$t/debian" "$t/deb/os-release"
    cat >"$t/deb/dpkg-status" <<'EOF'
Package: libssl3t64
Status: install ok installed
Architecture: amd64
Source: openssl
Version: 3.5.4-1~deb13u1
Description: Secure Sockets Layer toolkit

Package: libc6
Status: install ok installed
Source: glibc (2.41-12)
Version: 2.41-12+b1

Package: bash
Status: install ok installed
Version: 5.2.37-2

Package: openssl
Status: install ok installed
Source: openssl
Version: 3.5.4-1~deb13u1

Package: old-tool
Status: deinstall ok config-files
Version: 1.0-1
EOF
    out="$(list_packages "$t/deb")"
    st "dpkg status yields one sorted source-package line each" "$out" "$(printf '%s\n' 'Debian:13 bash 5.2.37-2' 'Debian:13 glibc 2.41-12' 'Debian:13 openssl 3.5.4-1~deb13u1')"

    mkdir -p "$t/apk"
    cp "$t/alpine" "$t/apk/os-release"
    cat >"$t/apk/apk-installed" <<'EOF'
C:Q1abc=
P:ca-certificates-bundle
V:20250911-r0
A:x86_64
o:ca-certificates

P:musl
V:1.2.5-r10
A:x86_64
o:musl

P:libcrypto3
V:3.5.4-r0
o:openssl

P:libssl3
V:3.5.4-r0
o:openssl
EOF
    out="$(list_packages "$t/apk")"
    st "apk installed db yields origin name and full version" "$out" "$(printf '%s\n' 'Alpine:v3.24 ca-certificates 20250911-r0' 'Alpine:v3.24 musl 1.2.5-r10' 'Alpine:v3.24 openssl 3.5.4-r0')"

    mkdir -p "$t/none"
    cp "$t/debian" "$t/none/os-release"
    st "an image with no package database is refused" "$(list_packages "$t/none" 2>/dev/null && echo ok || echo refused)" "refused"
    : >"$t/none/dpkg-status"
    st "an empty dpkg database is refused" "$(list_packages "$t/none" 2>/dev/null && echo ok || echo refused)" "refused"

    FIXTURE="$t/apk"
    docker() {
        case "$1" in
        create) echo cid1 ;;
        cp)
            local src="${*: -2:1}" dst="${*: -1}"
            case "$src" in
            cid1:/etc/os-release) cp "$FIXTURE/os-release" "$dst" ;;
            cid1:/lib/apk/db/installed) cp "$FIXTURE/apk-installed" "$dst" ;;
            *) return 1 ;;
            esac
            ;;
        rm) return 0 ;;
        esac
    }
    out="$(capture_image tor 'ghcr.io/test/pithead-tor@sha256:0')"
    st "capture_image falls back to the apk database and labels each line" "$(printf '%s\n' "$out" | head -1)" "tor Alpine:v3.24 ca-certificates 20250911-r0"
    FIXTURE="$t/none"
    st "capture_image fails when the image has no package database" "$(capture_image tor x 2>/dev/null && echo ok || echo failed)" "failed"
    unset -f docker

    [ "$fail" -eq 0 ] && echo "capture-packages self-test OK"
    return "$fail"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit
fi

[ "$#" -eq 2 ] || {
    echo "usage: $0 <label> <image-ref>" >&2
    exit 2
}
command -v docker >/dev/null 2>&1 || {
    echo "capture-packages: docker is required" >&2
    exit 1
}
capture_image "$1" "$2"
