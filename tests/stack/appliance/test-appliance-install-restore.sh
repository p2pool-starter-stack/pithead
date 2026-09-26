# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: a carried restore rearms a kept target — the two markers go, the chains stay (#2230) =="
# The installer block is run with its real state guard and deletion list; only its ESP path and
# block-device probe are repointed to a sandbox. A no-archive control preserves the old markers.
mk_tmpdir CRSB
crs_block=$(sed -n '/# A carried restore replaces the old configuration/,/^    fi$/p' "$ROOT/os/installer/pithead-install")
assert_contains "the carried-restore block is still where this row lifts it from" "$crs_block" 'rm -f "$restore_mnt/pithead/config.json"'
crs_block=${crs_block//\/boot\/efi\//\"\$CRS_ESP\"\/}
assert_contains "...and its ESP probe was repointed at the sandbox" "$crs_block" '"$CRS_ESP"/pithead-restore.enc'
crs_block=${crs_block//\[ -b \"\$data_part\" \]/[ -e \"\$data_part\" ]}
assert_contains "...and its device-node probe fell through to the stand-in" "$crs_block" '[ -e "$data_part" ]'
mkdir -p "$CRSB/esp" "$CRSB/part/pithead/data/monero" "$CRSB/part/pithead/data/tari" "$CRSB/part/pithead/data/p2pool"
printf '{"monero":{"wallet_address":"4kept"}}' >"$CRSB/part/pithead/config.json"
printf 'coordinator\n' >"$CRSB/part/pithead/machine-role"
for _c in monero tari p2pool; do printf 'KEEP-%s\n' "$_c" >"$CRSB/part/pithead/data/$_c/chain-sentinel"; done
crs_run() {
    [ "$1" = 1 ] && : >"$CRSB/esp/pithead-restore.enc" || rm -f "$CRSB/esp/pithead-restore.enc"
    rm -rf "$CRSB/out"
    cp -a "$CRSB/part" "$CRSB/out"
    (
        set +e
        # shellcheck disable=SC2034  # read inside the evaluated installer block
        CRS_ESP="$CRSB/esp" state=pithead-with-data target=/dev/fake-target
        die() {
            echo "die: $*" >&2
            exit 1
        }
        lsblk() { printf '%s\tdata\n' "$CRSB/stand-in-part"; }
        mount() { cp -a "$CRSB/part/." "$2/"; }
        umount() {
            rm -rf "$CRSB/out"
            cp -a "$1" "$CRSB/out"
        }
        rmdir() { rm -rf "${1:?}"; }
        eval "crs_main() { $crs_block
}"
        crs_main
    )
}
: >"$CRSB/stand-in-part"
crs_run 1
assert_rc "the carried-restore branch completes on a kept target" "$?" "0"
assert_eq "...config.json is cleared, so firstboot re-arms on the restored archive" "$([ -e "$CRSB/out/pithead/config.json" ] || echo gone)" "gone"
assert_eq "...machine-role is cleared, so pithead-boot does not take the provisioned fork" "$([ -e "$CRSB/out/pithead/machine-role" ] || echo gone)" "gone"
for _c in monero tari p2pool; do assert_eq "...the kept $_c chain is untouched" "$(cat "$CRSB/out/pithead/data/$_c/chain-sentinel" 2>/dev/null)" "KEEP-$_c"; done
crs_run 0
assert_eq "a kept target with no carried archive keeps its config.json" "$(jq -r '.monero.wallet_address' "$CRSB/out/pithead/config.json" 2>/dev/null)" "4kept"
assert_eq "...and keeps its role marker" "$(cat "$CRSB/out/pithead/machine-role" 2>/dev/null)" "coordinator"
rm -rf "$CRSB"
unset CRSB crs_block _c
unset -f crs_run
