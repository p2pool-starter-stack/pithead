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
chmod +x "$BL/bin/grub-editenv"
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

before=$(cat "$BL/grubenv")
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
        echo 'printf "%s\n%s\n%s\n" "$CURRENT_NAME (slot $CURRENT_SLOT, current)" "$A_TITLE" "$B_TITLE"'
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

rm -rf "$BL"
