#!/usr/bin/env bash
set -euo pipefail

apt_usage() {
    cat <<'USAGE'
Usage:
  apt.sh deb <bundle.tar.gz> <version> <out.deb>      repack the signed bundle tree as an amd64 package
  apt.sh feed <deb> <out-dir> <fingerprint> <pinned.asc>  build and sign a flat APT feed (needs the secret key in GNUPGHOME)
  apt.sh verify <feed-dir> <pinned.asc> <fingerprint> check the feed signatures against the pinned key
USAGE
}

apt_die() {
    printf 'apt.sh: %s\n' "$*" >&2
    exit 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGING="$HERE/../../packaging"

apt_deb() {
    local bundle=$1 version=$2 out=$3 root
    [ -f "$bundle" ] || apt_die "no bundle at $bundle"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || apt_die "package version must be a stable X.Y.Z, got '$version'"
    root=$(mktemp -d)
    trap 'rm -rf "$root"' RETURN
    mkdir -p "$root/usr/share/pithead" "$root/usr/bin" "$root/DEBIAN" "$root/usr/share/doc/pithead"
    tar -xzf "$bundle" --strip-components=1 -C "$root/usr/share/pithead"
    [ -x "$root/usr/share/pithead/pithead" ] || apt_die "the bundle has no pithead executable"
    [ "$(tr -d '[:space:]' <"$root/usr/share/pithead/VERSION")" = "$version" ] || apt_die "the bundle VERSION does not match $version"
    printf 'apt\n' >"$root/usr/share/pithead/PITHEAD_PACKAGE"
    install -m 755 "$PACKAGING/deb/pithead-wrapper" "$root/usr/bin/pithead"
    install -m 755 "$PACKAGING/deb/postinst" "$PACKAGING/deb/prerm" "$PACKAGING/deb/postrm" "$root/DEBIAN/"
    printf 'Pithead is distributed under the license in the project repository.\nhttps://github.com/p2pool-starter-stack/pithead\n' >"$root/usr/share/doc/pithead/copyright"
    cat >"$root/DEBIAN/control" <<CONTROL
Package: pithead
Version: $version
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Pithead <pithead@example.invalid>
Depends: bash, curl, jq, openssl, python3, sudo, docker.io | docker-ce, docker-compose-v2 | docker-compose-plugin
Homepage: https://github.com/p2pool-starter-stack/pithead
Description: Self-hosted Monero and Tari mining stack
 Installs the pinned Pithead program tree under /usr/share/pithead and keeps the
 working copy, configuration and data under /var/lib/pithead. Updates arrive
 through apt, which also moves the running stack to the new images.
CONTROL
    mkdir -p "$(dirname "$out")"
    dpkg-deb --root-owner-group --build "$root" "$out" >/dev/null
}

apt_feed() {
    local deb=$1 out=$2 fpr=$3 pinned=$4
    [ -f "$pinned" ] || apt_die "no pinned public key at $pinned"
    [ -f "$deb" ] || apt_die "no package at $deb"
    gpg --batch --list-secret-keys "$fpr" >/dev/null 2>&1 || apt_die "the secret key $fpr is not available"
    rm -rf "$out"
    mkdir -p "$out"
    cp "$deb" "$out/"
    cp "$pinned" "$out/pithead.asc"
    (
        cd "$out"
        apt-ftparchive packages . >Packages
        gzip -n -k -f Packages
        apt-ftparchive -o APT::FTPArchive::Release::Origin=pithead -o APT::FTPArchive::Release::Label=pithead \
            -o APT::FTPArchive::Release::Architectures=amd64 release . >Release
        gpg --batch --yes --armor --local-user "$fpr" --detach-sign --output Release.gpg Release
        gpg --batch --yes --armor --local-user "$fpr" --clearsign --output InRelease Release
    )
}

apt_verify() {
    local feed=$1 pinned=$2 want status home fpr
    want=$(printf '%s' "$3" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    [[ "$want" =~ ^[0-9A-F]{40}$ ]] || apt_die "the pinned fingerprint must be 40 hex digits"
    home=$(mktemp -d)
    trap 'rm -rf "$home"' RETURN
    chmod 700 "$home"
    export GNUPGHOME=$home
    fpr=$(gpg --batch --show-keys --with-colons "$pinned" | awk -F: '$1 == "fpr" {print $10; exit}')
    [ "$fpr" = "$want" ] || apt_die "the pinned key is $fpr, not $want"
    gpg --batch --import "$pinned" >/dev/null 2>&1
    cmp -s "$feed/pithead.asc" "$pinned" || apt_die "the feed publishes a key file that is not the pinned one"
    status=$(gpg --batch --status-fd 1 --verify "$feed/Release.gpg" "$feed/Release" 2>/dev/null) || apt_die "Release.gpg does not verify"
    grep -q "^\[GNUPG:\] VALIDSIG .* $want\$" <<<"$status" || apt_die "Release.gpg was not made by the pinned key"
    status=$(gpg --batch --status-fd 1 --verify "$feed/InRelease" 2>/dev/null) || apt_die "InRelease does not verify"
    gpg --batch --decrypt "$feed/InRelease" 2>/dev/null | cmp -s - "$feed/Release" || apt_die "InRelease and Release differ"
    grep -q "^\[GNUPG:\] VALIDSIG .* $want\$" <<<"$status" || apt_die "InRelease was not made by the pinned key"
    [ "$(find "$feed" -maxdepth 1 -name '*.deb' | wc -l | tr -d ' ')" = 1 ] || apt_die "the feed must hold exactly one package"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd=${1:-}
    shift || true
    case "$cmd" in
    deb)
        [ "$#" -eq 3 ] || {
            apt_usage >&2
            exit 2
        }
        apt_deb "$@"
        ;;
    feed)
        [ "$#" -eq 4 ] || {
            apt_usage >&2
            exit 2
        }
        apt_feed "$@"
        ;;
    verify)
        [ "$#" -eq 3 ] || {
            apt_usage >&2
            exit 2
        }
        apt_verify "$@"
        ;;
    *)
        apt_usage >&2
        exit 2
        ;;
    esac
fi
