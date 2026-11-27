#!/usr/bin/env bash
# Add the private kit's display-only label to a debug rootfs fixture, never a release export.
set -euo pipefail
export LC_ALL=C
label=${1:?label required}
tarball=${2:?rootfs tarball required}
[[ "$label" =~ ^[A-Za-z0-9.-]{1,16}$ ]] || exit 2
[ "$(tar -xOf "$tarball" etc/pithead-variant)" = debug ] || exit 2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/opt/pithead"
printf '%s\n' "$label" >"$work/opt/pithead/BUILD_LABEL"
tar -rf "$tarball" -C "$work" opt/pithead/BUILD_LABEL
