# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Boot-label metadata lifecycle and the GRUB label algorithm (#1956).
echo "== unit: boot menu version labels track RAUC slots (#1956) =="
BL="$SANDBOX/boot-labels"
mkdir -p "$BL/bin"
cat >"$BL/bin/grub-editenv" <<'SH'
#!/bin/sh
file=$1
op=$2
shift 2
case "$op" in
list) cat "$file" ;;
set)
    printf '%s\n' "$*" >>"$file.writes"
    for pair in "$@"; do
        key=${pair%%=*}
        sed "/^$key=/d" "$file" >"$file.tmp" 2>/dev/null || :
        printf '%s\n' "$pair" >>"$file.tmp"
        mv "$file.tmp" "$file"
    done
    ;;
*) exit 2 ;;
esac
SH
cat >"$BL/bin/findmnt" <<'SH'
#!/bin/sh
[ "$*" = '-no SOURCE /boot/efi' ] || exit 2
[ "${BL_MOUNT_FAIL:-0}" = 0 ] || exit 1
printf '/dev/fixture1\n'
SH
cat >"$BL/bin/lsblk" <<'SH'
#!/bin/sh
case "$*" in
'-no PKNAME /dev/fixture1') printf 'fixture\n' ;;
'-dno TRAN /dev/fixture')
    [ "${BL_TRAN:-}" != fail ] || exit 1
    printf '%s\n' "${BL_TRAN:-sata}" ;;
*) exit 2 ;;
esac
SH
chmod +x "$BL/bin/"*

printf 'ORDER="B A"\nA_VERSION=1.9.0\nB_VERSION=\n' >"$BL/grubenv"
printf 'quiet rauc.slot=A console=ttyS0\n' >"$BL/cmdline"
printf '2.0.0\n' >"$BL/VERSION"
(
    PATH="$BL/bin:$PATH"
    PITHEAD_GRUBENV="$BL/grubenv" PITHEAD_CMDLINE="$BL/cmdline" PITHEAD_VERSION_FILE="$BL/VERSION"
    export PITHEAD_GRUBENV PITHEAD_CMDLINE PITHEAD_VERSION_FILE
    # shellcheck source=os/overlay/pithead-boot-version
    source "$ROOT/os/overlay/pithead-boot-version"
    record_installed 2.1.0
    record_booted
)
assert_contains "the RAUC-primary spare records the installed version" "$(cat "$BL/grubenv")" "B_VERSION=2.1.0"
assert_contains "the booted slot repairs its own version metadata" "$(cat "$BL/grubenv")" "A_VERSION=2.0.0"
assert_contains "the update path records the RAUC-primary target" "$(cat "$ROOT/lib/pithead/15-os-update.sh")" \
    'pithead-boot-version record-installed "$bundle_version"'
# The repair must run on EVERY boot, which is why it is its own unit rather than a line in
# pithead-boot: that unit is gated on a PROVISIONED machine, so a slot filled by plain `rauc
# install` on a machine still at its setup page never got its version recorded and the console
# offered "empty (slot B, current)" for a good system (#1956, measured on the tier-4 battery).
# pithead-boot's own conditions are asserted beside it: without that control, "the repair unit
# has no ConditionPathExists" would also pass on an image where nothing is ever conditional.
bvu=$(cat "$ROOT/os/overlay/pithead-boot-version.service")
assert_contains "a dedicated unit repairs the booted slot's version" "$bvu" \
    "ExecStart=/usr/local/sbin/pithead-boot-version record-booted"
assert_eq "the repair is not gated on a provisioned machine" "$(grep -c '^ConditionPathExists=' <<<"$bvu")" "0"
assert_contains "the repair still refuses an unmounted ESP" "$bvu" "ConditionPathIsMountPoint=/boot/efi"
assert_eq "the control: pithead-boot IS gated on a provisioned machine" \
    "$(grep -c '^ConditionPathExists=|' "$ROOT/os/overlay/pithead-boot.service")" "2"
assert_eq "pithead-boot no longer carries the repair" \
    "$(grep -c 'pithead-boot-version' "$ROOT/os/overlay/pithead-boot")" "0"
assert_contains "the image enables the repair unit" "$(cat "$ROOT/os/rootfs/Dockerfile")" \
    "pithead-boot-version.service"
assert_contains "fresh image metadata names A and clears B" "$(cat "$ROOT/os/rauc/mkimage.sh")" \
    '"A_VERSION=$OS_VERSION" "B_VERSION="'
assert_contains "install-to-disk names A and keeps a retained B slot honest" "$(cat "$ROOT/os/installer/pithead-install")" \
    '"A_VERSION=$os_version" "B_VERSION=$b_version"'
assert_contains "a preserved-layout reinstall treats uninspected B as unknown" "$(cat "$ROOT/os/installer/pithead-install")" \
    'pithead-with-data" ] && b_version="unknown"'
# The repair is now its own unit, and the battery asserts `systemctl --failed` is empty (#792) —
# so a boot with nothing to record must exit 0, not red a machine that is otherwise fine. An image
# built with no updater has no `rauc.slot=` on its cmdline and is exactly that case. Driven through
# the CLI dispatch, not record_booted, because the tolerance lives there.
printf 'quiet console=ttyS0\n' >"$BL/no-slot-cmdline"
(
    PATH="$BL/bin:$PATH" PITHEAD_GRUBENV="$BL/grubenv" PITHEAD_CMDLINE="$BL/no-slot-cmdline" \
        PITHEAD_VERSION_FILE="$BL/VERSION" bash "$ROOT/os/overlay/pithead-boot-version" record-booted
) >/dev/null 2>&1
assert_rc "a boot with no slot to record does not fail its unit" "$?" "0"
# The control: with a slot on the cmdline the same dispatch really does write, so the row above
# cannot be earned by a dispatch that does nothing at all.
(
    PATH="$BL/bin:$PATH" PITHEAD_GRUBENV="$BL/grubenv" PITHEAD_CMDLINE="$BL/cmdline" \
        PITHEAD_VERSION_FILE="$BL/VERSION" bash "$ROOT/os/overlay/pithead-boot-version" record-booted
) >/dev/null 2>&1
assert_contains "…and the same dispatch still records a real A/B boot" "$(cat "$BL/grubenv")" "A_VERSION=2.0.0"

# Transport updates run independently of slot metadata, including updater-free boots.
for tran in usb sata nvme fail; do
    expected=internal
    [ "$tran" = usb ] && expected=usb
    printf 'MEDIA=stale\nA_VERSION=2.0.0\n' >"$BL/grubenv"
    PATH="$BL/bin:$PATH" BL_TRAN="$tran" PITHEAD_GRUBENV="$BL/grubenv" \
        PITHEAD_CMDLINE="$BL/no-slot-cmdline" PITHEAD_VERSION_FILE="$BL/VERSION" \
        bash "$ROOT/os/overlay/pithead-boot-version" record-booted >/dev/null 2>&1
    assert_rc "$tran transport without a slot never fails the unit" "$?" 0
    assert_contains "$tran transport records $expected media without a slot" "$(cat "$BL/grubenv")" "MEDIA=$expected"
    : >"$BL/grubenv.writes"
    PATH="$BL/bin:$PATH" BL_TRAN="$tran" PITHEAD_GRUBENV="$BL/grubenv" \
        PITHEAD_CMDLINE="$BL/cmdline" PITHEAD_VERSION_FILE="$BL/VERSION" \
        bash "$ROOT/os/overlay/pithead-boot-version" record-booted >/dev/null 2>&1
    assert_eq "unchanged $tran media is not rewritten when versions refresh" \
        "$(grep -c 'MEDIA=' "$BL/grubenv.writes")" 0
    assert_contains "version refresh preserves $tran media" "$(cat "$BL/grubenv")" "MEDIA=$expected"
    # Execute the installer's actual transport probe and seed, before any per-boot repair.
    (
        export PATH="$BL/bin:$PATH" BL_TRAN="$tran"
        target=/dev/fixture media=internal mnt="$BL" os_version=2.0.0 b_version=""
        mkdir -p "$mnt/boot/efi/grub"
        sed -n '/^    tran=$(lsblk/,/^    \[ "$tran" = usb \]/p' "$ROOT/os/installer/pithead-install" >"$BL/seed.sh"
        sed -n '/^    grub-editenv .* set ORDER=/,+1p' "$ROOT/os/installer/pithead-install" >>"$BL/seed.sh"
        export target media mnt os_version b_version
        bash -euo pipefail "$BL/seed.sh"
    )
    assert_rc "installer tolerates $tran transport under strict shell flags" "$?" 0
    assert_contains "installer seeds $tran target media before boot" \
        "$(cat "$BL/boot/efi/grub/grubenv")" "MEDIA=$expected"
done
before=$(cat "$BL/grubenv")
PATH="$BL/bin:$PATH" BL_MOUNT_FAIL=1 PITHEAD_GRUBENV="$BL/grubenv" \
    PITHEAD_CMDLINE="$BL/no-slot-cmdline" PITHEAD_VERSION_FILE="$BL/VERSION" \
    bash "$ROOT/os/overlay/pithead-boot-version" record-booted >/dev/null 2>&1
assert_rc "an unreadable ESP does not fail the boot unit" "$?" 0
assert_eq "an unreadable ESP leaves media metadata alone" "$(cat "$BL/grubenv")" "$before"

(
    PATH="$BL/bin:$PATH" PITHEAD_GRUBENV="$BL/grubenv" PITHEAD_CMDLINE="$BL/cmdline" \
        source "$ROOT/os/overlay/pithead-boot-version"
    record_installed '2.1.0;bad'
) >/dev/null 2>&1 || true
assert_eq "invalid version metadata cannot alter grubenv" "$(cat "$BL/grubenv")" "$before"

# Execute the actual assignment/selection block from grub.cfg after translating GRUB's `set X=`
# spelling to the shell equivalent. Fixtures replace load_env exactly where firmware would.
grub_fixture_titles() { # <env-file>
    local program="$BL/program.sh"
    {
        echo 'load_env() { source "$FIXTURE"; }'
        echo 'save_env() { :; }'
        sed -n '/^set ORDER=/,/^# A one-boot entry choice/p' "$ROOT/os/rauc/grub.cfg" |
            sed '$d; s/set \([A-Z_][A-Z_]*=\)/\1/g'
        echo 'printf "%s\n%s\n%s\n%s\n" "$CURRENT_TITLE" "$A_TITLE" "$B_TITLE" "$SETUP_TITLE"'
    } >"$program"
    FIXTURE="$1" bash "$program"
}

cat >"$BL/two" <<'EOF'
ORDER="A B"
A_OK=1
B_OK=1
A_TRY=0
B_TRY=0
A_VERSION=2.0.0
B_VERSION=1.20.0
EOF
titles=$(grub_fixture_titles "$BL/two")
assert_eq "two versions: selected slot is named current" "$(sed -n 1p <<<"$titles")" "Pithead 2.0.0 (slot A, current)"
assert_eq "two versions: other slot is named previous" "$(sed -n 3p <<<"$titles")" "Pithead 1.20.0 (slot B, previous)"

sed 's/^B_VERSION=.*/B_VERSION=/' "$BL/two" >"$BL/empty"
assert_eq "verified-empty slot says empty" "$(grub_fixture_titles "$BL/empty" | sed -n 3p)" "empty (slot B)"
sed 's/^B_VERSION=.*/B_VERSION=2.0.0/' "$BL/two" >"$BL/same"
assert_eq "same versions remain distinguishable by slot" "$(grub_fixture_titles "$BL/same" | sed -n 2,3p | tr '\n' '|')" \
    "Pithead 2.0.0 (slot A, current)|Pithead 2.0.0 (slot B, previous)|"
# The tier-4 failure, as a fixture: RAUC made B primary and committed, but nothing ever recorded
# B's version, so the entry the machine actually boots reads "empty" instead of naming its
# version. This is the state a `rauc install` leaves when no boot repairs it.
sed -e 's/^ORDER=.*/ORDER="B A"/' -e 's/^B_VERSION=.*/B_VERSION=/' "$BL/two" >"$BL/unrecorded"
assert_eq "an unrecorded primary slot names no version in the entry that boots" \
    "$(grub_fixture_titles "$BL/unrecorded" | sed -n 1p)" "empty (slot B, current)"
sed 's/^ORDER=.*/ORDER="B A"/' "$BL/two" >"$BL/committed"
assert_eq "a recorded primary slot names its version and its letter" \
    "$(grub_fixture_titles "$BL/committed" | sed -n 1,2p | tr '\n' '|')" \
    "Pithead 1.20.0 (slot B, current)|Pithead 2.0.0 (slot A, previous)|"
grep -v '^B_VERSION=' "$BL/two" >"$BL/legacy"
assert_eq "unset legacy metadata says unknown" "$(grub_fixture_titles "$BL/legacy" | sed -n 3p)" \
    "Pithead version unknown (slot B, previous)"
# All four titles carry the medium, including both empty overrides and an empty primary.
for medium in usb internal absent unknown; do
    prefix=""
    case "$medium" in
    usb) prefix="USB drive: " ;;
    internal) prefix="Internal disk: " ;;
    esac
    for fixture in two empty unrecorded legacy; do
        cp "$BL/$fixture" "$BL/media-fixture"
        [ "$medium" = absent ] || printf 'MEDIA=%s\n' "$medium" >>"$BL/media-fixture"
        base=$(grub_fixture_titles "$BL/$fixture")
        titles=$(grub_fixture_titles "$BL/media-fixture")
        for row in 1 2 3 4; do
            title=$(sed -n "${row}p" <<<"$titles")
            assert_eq "$medium $fixture title $row names its medium" "$title" "$prefix$(sed -n "${row}p" <<<"$base")"
            [ "${#title}" -le 72 ] && ok "$medium $fixture title $row fits 72 columns" || bad "title exceeds 72 columns: $title"
            LC_ALL=C grep -q '[^ -~]' <<<"$title" && bad "title is not ASCII: $title" || ok "$medium $fixture title $row is ASCII"
        done
    done
    # Explicitly drive the A-empty override as well as the B-empty fixture above.
    sed 's/^A_VERSION=.*/A_VERSION=/' "$BL/media-fixture" >"$BL/empty-a"
    assert_eq "$medium empty A title carries the medium" "$(grub_fixture_titles "$BL/empty-a" | sed -n 2p)" "${prefix}empty (slot A)"
done
assert_eq "setup wording fits the console with an internal prefix" \
    "$(grub_fixture_titles "$BL/two" | sed -n 4p)" "Set up again (setup wizard; keeps saved settings)"
assert_contains "the menu is emitted on the serial console" "$(cat "$ROOT/os/rauc/grub.cfg")" \
    "terminal_output console serial"
# shellcheck source=tests/os/boot-label-serial-verdict.sh
source "$ROOT/tests/os/boot-label-serial-verdict.sh"
printf 'Pithead 2.0.0 (slot B, current)\nPithead 2.0.0 (slot A, previous)\n' >"$BL/serial"
boot_label_serial_verdict "$BL/serial" 0 2.0.0 B A >/dev/null
assert_rc "serial verdict accepts both exact slot labels" "$?" "0"
mark=$(wc -c <"$BL/serial" | tr -d ' ')
printf 'Pithead 2.0.0 (slot A, current)\nPithead 2.0.0 (slot B, previous)\n' >>"$BL/serial"
boot_label_serial_verdict "$BL/serial" "$mark" 2.0.0 B A >/dev/null
assert_rc "serial verdict rejects matching labels from an earlier boot" "$?" "1"
boot_label_serial_verdict "$BL/serial" 0 2.0.1 B A >/dev/null
assert_rc "serial verdict rejects a stale version" "$?" "1"

printf 'Internal disk: Pithead 2.0.0 (slot B, current)\nInternal disk: Pithead 2.0.0 (slot A, previous)\nInternal disk: Set up again (setup wizard; keeps saved settings)\n' >"$BL/serial"
boot_label_serial_verdict "$BL/serial" 0 2.0.0 B A "Internal disk: " >/dev/null
assert_rc "serial verdict accepts complete media-prefixed menu titles" "$?" 0
sed -i 's/; keeps saved settings)/; keeps saved/' "$BL/serial"
boot_label_serial_verdict "$BL/serial" 0 2.0.0 B A "Internal disk: " >/dev/null
assert_rc "serial verdict rejects a truncated setup title" "$?" 1
printf 'Pithead 2.0.0 (slot B, current)\nPithead 2.0.0 (slot A, previous)\n' >"$BL/serial"
boot_label_serial_verdict "$BL/serial" 0 2.0.0 B A "Internal disk: " >/dev/null
assert_rc "serial verdict rejects missing media prefixes" "$?" 1

# Debug candidates in two slots stay distinguishable without changing the selected slot.
sed -e 's/^A_VERSION=.*/A_VERSION=2.0.0+abcdefghijklmnop/' -e 's/^B_VERSION=.*/B_VERSION=2.0.0+rc2/' "$BL/two" >"$BL/debug"
printf 'MEDIA=internal\n' >>"$BL/debug"
titles=$(grub_fixture_titles "$BL/debug")
assert_eq "debug slot keeps its own candidate" "$(sed -n 1p <<<"$titles")" "Internal disk: Pithead 2.0.0+abcdefghijklmnop (slot A, current)"
assert_eq "previous debug candidate stays visible" "$(sed -n 3p <<<"$titles")" "Internal disk: Pithead 2.0.0+rc2 (slot B, previous)"
for row in 1 2 3 4; do
    title=$(sed -n "${row}p" <<<"$titles")
    [ "${#title}" -le 72 ] && ok "maximum debug label title $row fits 72 columns" || bad "debug title exceeds 72 columns: $title"
done

rm -rf "$BL"
