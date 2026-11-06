#!/usr/bin/env bash

require_appliance_draft() {
    [ "${PITHEAD_REHEARSAL:-0}" = 1 ] && return 0
    [ "$DRAFT" -eq 1 ] || die "Appliance releases require --draft; only the owner publishes after manual image verification."
    [ "$UNSIGNED" -eq 0 ] || die "Appliance releases require signatures; --unsigned is not supported."
}

require_appliance_inputs() {
    local name
    for name in PITHEAD_RAUC_KEYRING PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY; do
        [ -n "${!name:-}" ] && [ -f "${!name}" ] && [ -s "${!name}" ] && [ -r "${!name}" ] ||
            die "$name must name a readable, nonempty release signing file."
    done
    case "${PITHEAD_DATA_MIGRATION:-}" in
    true | false) ;;
    *) die "Declare PITHEAD_DATA_MIGRATION=true|false for the release." ;;
    esac
    [ "${PITHEAD_MIN_OS_VERSION+x}" = x ] || die "Declare PITHEAD_MIN_OS_VERSION (set but empty for no floor)."
    [ -z "$PITHEAD_MIN_OS_VERSION" ] || [[ "$PITHEAD_MIN_OS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "PITHEAD_MIN_OS_VERSION must be X.Y.Z or empty."
    [ "$PITHEAD_DATA_MIGRATION" = false ] || [ -n "$PITHEAD_MIN_OS_VERSION" ] ||
        die "A migrating release must declare PITHEAD_MIN_OS_VERSION=X.Y.Z."
}

appliance_identity() (
    set -euo pipefail
    image=$1 bundle=$2 keyring=$3 version=$4 commit=$5 variant=$6
    loop="" mounted=0
    work=$(mktemp -d "${TMPDIR:?}/pithead-appliance-identity.XXXXXX")
    cleanup_appliance_identity() {
        local rc=$?
        if [ "$mounted" -eq 1 ]; then umount "$work/root" || rc=1; fi
        if [ -n "$loop" ]; then losetup -d "$loop" || rc=1; fi
        rm -r "$work" || rc=1
        exit "$rc"
    }
    trap cleanup_appliance_identity EXIT
    mkdir "$work/root"
    loop=$(losetup --read-only -Pf --show "$image")
    wait_loop_partitions "$loop"
    mount -o ro "${loop}p2" "$work/root"
    mounted=1
    cmp "$keyring" "$work/root/etc/rauc/keyring.pem"
    [ "$(cat "$work/root/opt/pithead/BUILD_COMMIT")" = "$commit" ]
    [ "$(tr -d '[:space:]' <"$work/root/opt/pithead/VERSION")" = "$version" ]
    [ "$(cat "$work/root/etc/pithead-variant")" = "$variant" ]
    ref=$(sed -n 's/^ARG RIGFORGE_REF=//p' os/rootfs/Dockerfile)
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]]
    baked_version=$(tr -d '[:space:]' <"$work/root/opt/rigforge/VERSION")
    [[ "$baked_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]
    [ "$(cat "$work/root/opt/rigforge/RIGFORGE_REF")" = "ref=$ref version=$baked_version" ]
    metadata=$(rauc info --keyring "$work/root/etc/rauc/keyring.pem" --output-format=shell "$bundle")
    grep -Fxq "RAUC_MF_COMPATIBLE='pithead-amd64'" <<<"$metadata"
    grep -Fxq "RAUC_MF_VERSION='$version'" <<<"$metadata"
    grep -Fxq "RAUC_META_PITHEAD_VERSION='$version'" <<<"$metadata"
    grep -Fxq "RAUC_META_PITHEAD_VARIANT='$variant'" <<<"$metadata"
    if [ "$variant" = release ]; then
        grep -Fxq "RAUC_META_PITHEAD_DATA_MIGRATION='$PITHEAD_DATA_MIGRATION'" <<<"$metadata"
        if [ -n "$PITHEAD_MIN_OS_VERSION" ]; then
            grep -Fxq "RAUC_META_PITHEAD_MINIMUM_OS_VERSION='$PITHEAD_MIN_OS_VERSION'" <<<"$metadata"
        else
            ! grep -q '^RAUC_META_PITHEAD_MINIMUM_OS_VERSION=' <<<"$metadata"
        fi
    fi
    printf -- '- baked RigForge: `%s` (version `%s`)\n' "$ref" "$baked_version"
)

appliance_assets() {
    local dir=$1 tag=$2 name digest
    for name in "pithead-os-$tag.img.xz" "pithead-os-$tag.raucb"; do
        [ -f "$dir/$name" ] && [ -s "$dir/$name" ] && [ "$(wc -c <"$dir/$name")" -lt 2147483648 ] ||
            die "Missing, empty or oversized appliance asset: $name."
        digest=$(sha256sum "$dir/$name" | cut -d' ' -f1) || return 1
        [ "$(cat "$dir/$name.sha256")" = "$digest  $name" ] || die "Appliance checksum mismatch: $name."
    done
    xz -t "$dir/pithead-os-$tag.img.xz" || die "Invalid compressed appliance image."
}

prepare_appliance() {
    stage "6c/7  Build and verify appliance assets"
    require_appliance_inputs
    run sudo env "TMPDIR=${TMPDIR:-$WORKDIR}" "PITHEAD_EXPECT_COMMIT=$GIT_COMMIT" \
        "PITHEAD_RAUC_KEYRING=$PITHEAD_RAUC_KEYRING" "PITHEAD_RAUC_CERT=$PITHEAD_RAUC_CERT" \
        "PITHEAD_RAUC_KEY=$PITHEAD_RAUC_KEY" "PITHEAD_DATA_MIGRATION=$PITHEAD_DATA_MIGRATION" \
        "PITHEAD_MIN_OS_VERSION=$PITHEAD_MIN_OS_VERSION" \
        bash scripts/release/appliance.sh "$WORKDIR" "$GIT_COMMIT"
}

build_release_appliance() {
    local out=$1 commit=$2 version image bundle
    version=$(tr -d '[:space:]' <VERSION)
    image="$out/appliance-system.img"
    bundle="$out/appliance-update.raucb"
    require_appliance_inputs
    os/rauc/mkimage.sh "$image"
    os/rauc/mkbundle.sh "$bundle"
    PITHEAD_EXPECT_COMMIT="$commit" tests/os/verify-image.sh "$image"
    appliance_identity "$image" "$bundle" "$PITHEAD_RAUC_KEYRING" "$version" "$commit" release >"$out/appliance-rigforge.md"
    scripts/release/package-appliance.sh "$image" "$bundle" "$out/appliance"
    appliance_assets "$out/appliance" "v$version"
    cmp "$bundle" "$out/appliance/pithead-os-v$version.raucb"
    xz -dc "$out/appliance/pithead-os-v$version.img.xz" | cmp "$image" -
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    cd "$(dirname "$0")/../.."
    die() {
        printf '%s\n' "$*" >&2
        exit 1
    }
    # shellcheck source=os/rauc/loop-wait.sh
    source os/rauc/loop-wait.sh
    if [ "${1:-}" = --identity ]; then
        shift
        [ "$#" -eq 6 ] || die "usage: appliance.sh --identity IMAGE BUNDLE KEYRING VERSION COMMIT VARIANT"
        appliance_identity "$@"
        exit 0
    fi
    [ "$#" -eq 2 ] && [[ "$2" =~ ^[0-9a-f]{40}$ ]] || die "usage: appliance.sh OUTPUT_DIR FULL_COMMIT"
    [ "$(git rev-parse HEAD)" = "$2" ] || die "Appliance source commit mismatch."
    build_release_appliance "$1" "$2"
fi
