# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: pithead-install --target-serial resolves exactly one installable disk =="
mk_tmpdir HSI
sed '$d' "$ROOT/os/installer/pithead-install" >"$HSI/installer-lib.sh"
hsi_resolve() { # <lsblk-json> <serial> [mounted-disk]
    (
        # shellcheck disable=SC1091
        source "$HSI/installer-lib.sh"
        set +eu
        HSI_JSON="$1" HSI_MOUNTED="${3:-}"
        export HSI_JSON HSI_MOUNTED
        lsblk() {
            case "$*" in
            -Jdno*) printf '%s' "$HSI_JSON" ;;
            "-no MOUNTPOINTS /dev/$HSI_MOUNTED") [ -z "$HSI_MOUNTED" ] || echo /mnt ;;
            "-no PKNAME"*) echo sda ;;
            esac
        }
        findmnt() { echo /dev/sda2; }
        blockdev() { return 1; }
        dumpe2fs() { return 1; }
        resolve_target_serial "$2"
    ) 2>&1
}
two_disks() { # <first-name> <first-serial> <second-name> <second-serial>
    printf '{"blockdevices":[{"name":"sda","size":"16G","model":"Stick","serial":"BOOT1","type":"disk"},{"name":"%s","size":"1T","model":"M","serial":"%s","type":"disk"},{"name":"%s","size":"1T","model":"M","serial":"%s","type":"disk"}]}' "$1" "$2" "$3" "$4"
}
assert_eq "named serial resolves to its /dev path" "$(hsi_resolve "$(two_disks vda AAA111 vdb BBB222)" BBB222)" "/dev/vdb"
assert_eq "swapping the enumeration order still lands on the serial" "$(hsi_resolve "$(two_disks vdb BBB222 vda AAA111)" BBB222)" "/dev/vdb"
hsi_out=$(hsi_resolve "$(two_disks vda AAA111 vdb BBB222)" CCC333)
assert_contains "no match refuses and lists the candidates" "$hsi_out" "0 installable disks carry serial CCC333"
assert_contains "no match output names the offered serials" "$hsi_out" "BBB222"
hsi_out=$(hsi_resolve "$(two_disks vda DUP9 vdb DUP9)" DUP9)
assert_contains "a serial on two disks refuses" "$hsi_out" "2 installable disks carry serial DUP9"
hsi_out=$(hsi_resolve "$(two_disks vda AAA111 vdb unknown)" unknown)
assert_contains "'unknown' is refused" "$hsi_out" "real serial"
hsi_out=$(hsi_resolve "$(two_disks vda AAA111 vdb BBB222)" '')
assert_contains "an empty serial is refused" "$hsi_out" "real serial"
hsi_out=$(hsi_resolve "$(two_disks vda AAA111 vdb BBB222)" 'AAA;rm')
assert_contains "characters outside the serial alphabet are refused" "$hsi_out" "outside"
hsi_out=$(hsi_resolve "$(two_disks vda AAA111 vdb BBB222)" BOOT1)
assert_contains "the booted medium's serial is never offered" "$hsi_out" "0 installable disks carry serial BOOT1"
hsi_out=$(hsi_resolve "$(two_disks vda AAA111 vdb BBB222)" BBB222 vdb)
assert_contains "a disk with mounted filesystems is never offered" "$hsi_out" "0 installable disks carry serial BBB222"
hsi_out=$(hsi_resolve '{"blockdevices":[{"name":"sda","size":"16G","model":"S","serial":"BOOT1","type":"disk"},{"name":"vda","size":"1T","model":"M","serial":"0123","type":"disk"}]}' 123)
assert_contains "serials compare as strings, not numbers" "$hsi_out" "0 installable disks carry serial 123"
rm -rf "$HSI"
unset HSI hsi_out

echo "== unit: the serial file on the installation medium =="
mk_tmpdir HSP
export PITHEAD_PRESEED_DIR="$HSP"
run_sourced "$SANDBOX" preseed_target_serials >/dev/null 2>&1
assert_rc "no serial file -> rc 2 (not requested)" "$?" "2"
printf 'AAA111\r\n\n  BBB222  \nCCC333' >"$HSP/pithead-target-serial.txt"
assert_eq "serials read one per line, CR and padding stripped" "$(run_sourced "$SANDBOX" preseed_target_serials 2>&1 | tr '\n' ' ')" "AAA111 BBB222 CCC333 "
for hsp_bad in 'unknown' 'AAA;rm -rf /' '$(id)' '' '   '; do
    printf '%s\n' "$hsp_bad" >"$HSP/pithead-target-serial.txt"
    run_sourced "$SANDBOX" preseed_target_serials >/dev/null 2>&1
    assert_rc "unusable serial line '$hsp_bad' -> rc 1" "$?" "1"
done
printf 'AAA111\nbad serial\n' >"$HSP/pithead-target-serial.txt"
run_sourced "$SANDBOX" preseed_target_serials >/dev/null 2>&1
assert_rc "one bad line among good ones refuses the whole file" "$?" "1"

echo "== unit: headless_install erases only on one exact match with a valid config =="
cat >"$HSP/fake-install" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "--list" ]; then
    printf 'vda\t1T\tM\t%s\tpithead-with-data\n' "${HS_SER_A:-AAA111}"
    printf 'vdb\t1T\tM\t%s\tpithead\n' "${HS_SER_B:-BBB222}"
    exit 0
fi
printf '%s\n' "$*" >>"${HS_LOG:?}"
[ -z "${HS_FAIL:-}" ]
FAKE
chmod +x "$HSP/fake-install"
hsp_run() {
    : >"$HSP/install.log"
    (
        cd "$SANDBOX" || exit
        source "$STACK"
        set +e
        mutation_lock_acquire() { :; }
        mutation_lock_release() { :; }
        wizard_install_finish() { echo "FINISH $3" >>"$HSP/install.log"; }
        PITHEAD_INSTALL_BIN="$HSP/fake-install" HS_LOG="$HSP/install.log" TMPDIR="$HSP" headless_install "$HSP"
    ) >"$HSP/out.txt" 2>&1
    echo $?
}
printf 'BBB222\n' >"$HSP/pithead-target-serial.txt"
rm -f "$HSP/pithead-config.json"
assert_eq "a serial file without a config opens the page" "$(hsp_run)" "1"
assert_eq "...and installs nothing" "$(cat "$HSP/install.log")" ""
printf '{"monero":{"wallet_address":"nope"},"tari":{"wallet_address":"t"}}' >"$HSP/pithead-config.json"
assert_eq "a rejected config opens the page" "$(hsp_run)" "1"
assert_eq "...and installs nothing" "$(cat "$HSP/install.log")" ""
printf '{"monero":{"wallet_address":"%s"},"tari":{"wallet_address":"'"$VALID_TARI"'"},"p2pool":{"pool":"mini","stratum_password":"auto"}}' \
    "$VALID_PRIMARY" >"$HSP/pithead-config.json"
assert_eq "one match installs" "$(hsp_run)" "0"
assert_eq "the install is by serial, keeps data, and is confirmed" "$(cat "$HSP/install.log")" "--target-serial BBB222 --wipe keep --yes"
printf 'ZZZ999\n' >"$HSP/pithead-target-serial.txt"
assert_eq "no matching disk opens the page" "$(hsp_run)" "1"
assert_eq "...and installs nothing" "$(cat "$HSP/install.log")" ""
printf 'AAA111\nBBB222\n' >"$HSP/pithead-target-serial.txt"
assert_eq "a list matching two attached disks opens the page" "$(hsp_run)" "1"
assert_eq "...and installs nothing" "$(cat "$HSP/install.log")" ""
printf 'BBB222\nZZZ999\n' >"$HSP/pithead-target-serial.txt"
assert_eq "a list with one attached member installs" "$(hsp_run)" "0"
HS_SER_A=BBB222
export HS_SER_A
assert_eq "the same serial on two disks opens the page" "$(hsp_run)" "1"
assert_eq "...and installs nothing" "$(cat "$HSP/install.log")" ""
unset HS_SER_A
HS_FAIL=1
export HS_FAIL
assert_eq "a failing install reports failure" "$(hsp_run)" "1"
unset HS_FAIL
rm -f "$HSP/pithead-target-serial.txt"
assert_eq "no serial file is not a headless request" "$(hsp_run)" "2"
assert_eq "...and installs nothing" "$(cat "$HSP/install.log")" ""
rm -rf "$HSP"
unset HSP hsp_bad PITHEAD_PRESEED_DIR
