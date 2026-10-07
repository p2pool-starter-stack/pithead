#!/usr/bin/env bash
# Display labels at all three grubenv writers, release refusal, and serial negative controls.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/slot/opt/pithead" "$T/bin"
printf '2.0.0\n' >"$T/slot/opt/pithead/VERSION"
version_file="$T/slot/opt/pithead/VERSION"
assert_eq() { [ "$1" = "$2" ] || {
    printf 'FAIL: %s: expected [%s], got [%s]\n' "$3" "$2" "$1"
    exit 1
}; }
menu_version() { bash "$ROOT/os/overlay/pithead-boot-version" menu-version "$version_file"; }
assert_eq "$(menu_version)" 2.0.0 'absent label'
for label in rc3 a A-1.0123456789ab; do
    printf '%s\n' "$label" >"$T/slot/opt/pithead/BUILD_LABEL"
    assert_eq "$(menu_version)" "2.0.0+$label" 'valid label'
done
for label in '' 'rc 3' 'rc_3' '+rc3' 'rc3;echo' 'abcdefghijklmnopq' $'rc3\nrc4' $'rc3\r'; do
    printf '%s\n' "$label" >"$T/slot/opt/pithead/BUILD_LABEL"
    assert_eq "$(menu_version)" 2.0.0 'malformed label ignored'
done
printf 'rc3\0\n' >"$T/slot/opt/pithead/BUILD_LABEL"
assert_eq "$(menu_version)" 2.0.0 'NUL ignored'
printf 'rc3\n\n' >"$T/slot/opt/pithead/BUILD_LABEL"
assert_eq "$(menu_version)" 2.0.0 'extra lines ignored'
printf 'rc3\n' >"$T/slot/opt/pithead/BUILD_LABEL"
cat >"$T/bin/grub-editenv" <<'SH'
#!/bin/bash
case "$2" in
list) cat "$1" ;;
set) shift 2; printf '%s\n' "$@" >"$GRUB_WRITES" ;;
*) exit 2 ;;
esac
SH
chmod +x "$T/bin/grub-editenv"
export PATH="$T/bin:$PATH" GRUB_WRITES="$T/writes"
printf 'rauc.slot=A\n' >"$T/cmdline"
printf 'ORDER=B A\n' >"$T/env"
(
    export PITHEAD_GRUBENV="$T/env" PITHEAD_CMDLINE="$T/cmdline" PITHEAD_VERSION_FILE="$version_file"
    # shellcheck source=os/overlay/pithead-boot-version
    source "$ROOT/os/overlay/pithead-boot-version"
    record_booted
    assert_eq "$(cat "$T/writes")" A_VERSION=2.0.0+rc3 'booted slot'
    record_installed 2.0.0
    assert_eq "$(cat "$T/writes")" B_VERSION=2.0.0 'bundle remains plain'
)
# Execute the actual builder and installer assignments, substituting only their filesystem roots.
for label in absent rc3 'bad label'; do
    if [ "$label" = absent ]; then
        rm -f "$T/slot/opt/pithead/BUILD_LABEL"
    else
        printf '%s\n' "$label" >"$T/slot/opt/pithead/BUILD_LABEL"
    fi
    expected=2.0.0
    [ "$label" != rc3 ] || expected=2.0.0+rc3
    for writer in os/rauc/mkimage.sh os/installer/pithead-install; do
        sed -n '/^OS_VERSION=/p; /^    os_version=/p' "$ROOT/$writer" |
            sed "s#/mnt/rauc-sys#$T/slot#g; s#/usr/local/sbin/pithead-boot-version#bash $ROOT/os/overlay/pithead-boot-version#g; s#menu-version)#menu-version $version_file)#g; s#<VERSION)#<$version_file)#g; s#</opt/pithead/VERSION)#<$version_file)#g" >"$T/seed.sh"
        # shellcheck disable=SC1090
        source "$T/seed.sh"
        assert_eq "${OS_VERSION:-${os_version:-}}" "$expected" "$writer $label seed"
        unset OS_VERSION os_version
    done
    export PITHEAD_GRUBENV="$T/env" PITHEAD_CMDLINE="$T/cmdline" PITHEAD_VERSION_FILE="$version_file"
    bash "$ROOT/os/overlay/pithead-boot-version" record-booted 2>/dev/null
    assert_eq "$(cat "$T/writes")" "A_VERSION=$expected" "$label booted seed"
done
assert_eq "$(cat "$version_file")" 2.0.0 'VERSION unchanged'
# Real release entry points must reject a labelled release tar before signing or mounting anything.
mkdir -p "$T/repo/os/rauc" "$T/repo/os/build" "$T/slot/etc"
cp "$ROOT"/os/rauc/{mkimage,mkbundle,populate-slot,loop-wait}.sh "$T/repo/os/rauc/"
cp "$ROOT/VERSION" "$T/repo/VERSION"
printf 'release\n' >"$T/slot/etc/pithead-variant"
for label in rc3 '' 'bad label'; do
    printf '%s\n' "$label" >"$T/slot/opt/pithead/BUILD_LABEL"
    tar -cf "$T/repo/os/build/pithead-root.tar" -C "$T/slot" etc opt
    for writer in mkimage mkbundle; do
        rc=0
        PITHEAD_STALE_TARBALL_OK=1 PITHEAD_DATA_MIGRATION=false PITHEAD_MIN_OS_VERSION='' \
            bash "$T/repo/os/rauc/$writer.sh" >"$T/guard.log" 2>&1 || rc=$?
        assert_eq "$rc" 2 "$writer refuses labelled release"
        grep -q 'refusing a rootfs carrying BUILD_LABEL' "$T/guard.log"
    done
done
# The fixture stamp is confined to debug rootfs, as is the private kit's producer.
if bash "$ROOT/tests/os/build-label-fixture.sh" rc3 "$T/repo/os/build/pithead-root.tar"; then
    echo 'FAIL: fixture stamped a release rootfs'
    exit 1
fi
printf 'debug\n' >"$T/slot/etc/pithead-variant"
rm "$T/slot/opt/pithead/BUILD_LABEL"
tar -cf "$T/debug.tar" -C "$T/slot" etc opt
bash "$ROOT/tests/os/build-label-fixture.sh" rc3 "$T/debug.tar"
assert_eq "$(tar -xOf "$T/debug.tar" opt/pithead/BUILD_LABEL)" rc3 'kit fixture label'
# First menus and mixed-slot versions must be read from this boot's serial, not an earlier one.
printf 'USB drive: Pithead 2.0.0+rc3 (slot A, current)\n' >"$T/serial"
bash "$ROOT/tests/os/build-label-boot-leg.sh" "$T/serial" 0 2.0.0 rc3 usb A
if bash "$ROOT/tests/os/build-label-boot-leg.sh" "$T/serial" "$(wc -c <"$T/serial")" 2.0.0 rc3 usb A; then
    echo 'FAIL: accepted an earlier boot'
    exit 1
fi
if bash "$ROOT/tests/os/build-label-boot-leg.sh" "$T/serial" 0 2.0.0 '' usb A; then
    echo 'FAIL: accepted a label as plain'
    exit 1
fi
# shellcheck source=tests/os/boot-label-serial-verdict.sh
source "$ROOT/tests/os/boot-label-serial-verdict.sh"
printf 'Internal disk: Pithead 2.0.0 (slot B, current)\nInternal disk: Pithead 2.0.0+rc3 (slot A, previous)\nInternal disk: Set up again (setup wizard; keeps saved settings)\n' >"$T/serial"
boot_label_serial_verdict "$T/serial" 0 2.0.0 B A 'Internal disk: ' 2.0.0+rc3
if boot_label_serial_verdict "$T/serial" 0 2.0.0 B A 'Internal disk: '; then
    echo 'FAIL: mixed slot versions accepted as identical'
    exit 1
fi
printf '\nBUILD_LABEL selftest passed\n'
