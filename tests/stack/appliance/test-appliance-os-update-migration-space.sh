# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The room a data-migrating OS update needs on the Tari data volume (#2645). A data_migration bundle
# releases the chain services once its slot commits, and a Tari major then writes a compacted copy
# of data.mdb beside the old one. os_update_migration_space_guard refuses the install first, with
# `pithead upgrade`'s sizing (#2636), and both doors run it: the `os-update` CLI and the dashboard's
# os-verify/os-install verbs. df, rauc and systemctl are stubs on PATH, and data.mdb is a sparse
# 100 GiB file, so the database costs no disk. Sourced by tests/stack/run.sh.

MS="$SANDBOX/os-migration-space"
mkdir -p "$MS/bin" "$MS/tari/mainnet/data/base_node/db"
truncate -s 100G "$MS/tari/mainnet/data/base_node/db/data.mdb"
# Stub df: column 4 (Available, KiB) of the second line, on the appliance's data mount. It answers
# only for a path under the Tari data dir, so a guard that measured another volume would not refuse.
cat >"$MS/bin/df" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in "$MS_DF_ROOT"/*) ;; *) exit 1 ;; esac
[ "${MS_DF_FAIL:-0}" = 1 ] && exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/vdb1 999999999 1 %s 1%% /data\n' "${MS_AVAIL_KB:-999999999}"
EOF
chmod +x "$MS/bin/df"
export MS_DF_ROOT="$MS/tari"
ms_env() { # <TARI_MODE or empty> — the .env the guard reads the Tari mode and data dir from
    printf 'TARI_DATA_DIR=%s\n' "$MS/tari" >"$MS/.env"
    [ -z "$1" ] || printf 'TARI_MODE=%s\n' "$1" >>"$MS/.env"
}
ms_guard() { # <data_migration value> <avail GiB> — the guard's stdout and stderr
    MS_AVAIL_KB=$(($2 * 1048576)) PATH="$MS/bin:$PATH" run_sourced "$MS" os_update_migration_space_guard "$1" 2>&1
}

echo "== unit: os_update_migration_space_guard (#2645) =="
ms_env local
out="$(ms_guard true 50)"
assert_contains "a migrating bundle on a volume without room is refused" "$out" "Refusing: this update declares a chain data migration"
assert_contains "the refusal names the volume" "$out" "on /data"
assert_contains "the refusal names the size needed (data.mdb + 5 GiB margin)" "$out" "about 105 GiB free"
assert_contains "the refusal names the size free" "$out" "and it has 50 GiB free"
assert_contains "the refusal says nothing was installed" "$out" "Nothing was installed."
assert_eq "room for the copy plus the margin passes" "$(ms_guard true 105)" ""
assert_contains "inside the 5 GiB margin still refuses" "$(ms_guard true 104)" "Refusing"
assert_eq "a bundle without data_migration passes on a full volume" "$(ms_guard false 1)" ""
assert_eq "an unstamped data_migration passes on a full volume" "$(ms_guard "" 1)" ""
ms_env ""
assert_contains "an .env without TARI_MODE is checked as local" "$(ms_guard true 50)" "Refusing"
ms_env remote
assert_eq "a remote Tari node migrates nothing here" "$(ms_guard true 1)" ""
ms_env off
assert_eq "Tari off migrates nothing here" "$(ms_guard true 1)" ""
ms_env local
out="$(MS_DF_FAIL=1 ms_guard true 1)"
assert_not_contains "free space unreadable: no refusal on a guess" "$out" "Refusing"
assert_contains "…but warns that the check did not run" "$out" "was not checked"
mv "$MS/tari/mainnet/data/base_node/db/data.mdb" "$MS/data.mdb.aside"
assert_eq "no Tari database passes" "$(ms_guard true 1)" ""
mv "$MS/data.mdb.aside" "$MS/tari/mainnet/data/base_node/db/data.mdb"

echo "== unit: os-update refuses a migrating bundle before rauc install (#2645) =="
cat >"$MS/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info) [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT" ;;
install) echo "installing bundle: 100%" ;;
esac
exit 0
EOF
chmod +x "$MS/bin/rauc"
touch "$MS/bundle.raucb"
printf 'release\n' >"$MS/variant-release"
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='2.0.0'\nRAUC_META_PITHEAD_DATA_MIGRATION='true'\nRAUC_META_PITHEAD_MINIMUM_OS_VERSION='2.0.0'\n" >"$MS/info-mig.txt"
ms_os_update() { # <avail GiB> — os-update of the migrating bundle, stdin closed
    rm -f "$MS/floor" "$MS/floor.prev" "$MS/marker"
    : >"$MS/rauc.log"
    (
        cd "$MS" || exit
        PATH="$MS/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        MS_AVAIL_KB=$(($1 * 1048576)) RAUC_LOG="$MS/rauc.log" RAUC_INFO_OUT="$MS/info-mig.txt" \
            PITHEAD_VERSION=1.20.0 PITHEAD_VARIANT_FILE="$MS/variant-release" \
            PITHEAD_DATA_FLOOR_FILE="$MS/floor" PITHEAD_MIGRATION_MARKER_FILE="$MS/marker" \
            os_update bundle.raucb </dev/null
    )
}
out=$(ms_os_update 50 2>&1)
assert_rc "os-update of a migrating bundle without room exits 1" "$?" "1"
assert_contains "…with the shared refusal" "$out" "about 105 GiB free on /data (Tari's data.mdb plus a 5 GiB margin), and it has 50 GiB free"
assert_not_contains "…before rauc install" "$(cat "$MS/rauc.log")" "install"
assert_eq "…with no migration marker written" "$([ -f "$MS/marker" ] && echo present || echo absent)" "absent"
assert_eq "…and no /data floor raised" "$([ -f "$MS/floor" ] && echo present || echo absent)" "absent"
ms_os_update 200 >/dev/null 2>&1
assert_rc "os-update of a migrating bundle with room exits 0" "$?" "0"
assert_contains "…and installs" "$(cat "$MS/rauc.log")" "install bundle.raucb"
assert_eq "…and marks the migration pending" "$(tr -d ' \n' <"$MS/marker" 2>/dev/null)" "2.0.0"

echo "== black-box: the dashboard's os-verify and os-install refuse it too, and keep the download (#2645) =="
MSC="$MS/control"
MSRES="$MSC/data/control/results"
MSDIR="$MSC/osdir"
mkdir -p "$MSC/data/control/requests" "$MSC/data/control/staged" "$MSRES" "$MSC/data/control/audit" "$MSDIR"
cp "$STACK" "$MSC/pithead"
make_stubs "$MSC/bin"
cp "$MS/bin/df" "$MS/bin/rauc" "$MSC/bin/"
cat >"$MSC/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MSC/bin/systemctl"
printf '1.20.0' >"$MSC/VERSION"
printf '{}' >"$MSC/config.json"
cat >"$MSC/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$MSC/data/control
TARI_MODE=local
TARI_DATA_DIR=$MS/tari
EOF
printf 'compatible=pithead-os\n' >"$MSC/system.conf"
printf "RAUC_MF_COMPATIBLE='pithead-os'\n" | cat - "$MS/info-mig.txt" >"$MSC/info-mig.txt"
printf '{"tag":"v2.0.0","size":1000}\n' >"$MSDIR/target.json"
MSU="99999999-9999-4999-8999-999999999999"
ms_verb() { # <action> <avail GiB> — one staged bundle, one request, one drain
    [ -f "$MSDIR/pithead-os-v2.0.0.raucb" ] || yes x | head -c 1000 >"$MSDIR/pithead-os-v2.0.0.raucb"
    rm -f "$MSRES/$MSU.json"
    : >"$MS/rauc.log"
    printf '{"id":"%s","action":"%s","actor":"admin"}\n' "$MSU" "$1" >"$MSC/data/control/requests/$MSU.json"
    (cd "$MSC" && PATH="$MSC/bin:$PATH" MS_AVAIL_KB=$(($2 * 1048576)) RAUC_LOG="$MS/rauc.log" \
        RAUC_INFO_OUT="$MSC/info-mig.txt" PITHEAD_APPLIANCE=1 PITHEAD_OS_UPDATE_DIR="$MSDIR" \
        PITHEAD_VARIANT_FILE="$MS/variant-release" PITHEAD_DATA_FLOOR_FILE="$MSC/floor" \
        PITHEAD_RAUC_SYSTEM_CONF="$MSC/system.conf" PITHEAD_MIGRATION_MARKER_FILE="$MSC/marker" \
        ./pithead control-run-pending >/dev/null 2>&1)
}
ms_staged() { [ -f "$MSDIR/pithead-os-v2.0.0.raucb" ] && echo present || echo absent; }
for verb in os-verify os-install; do
    ms_verb "$verb" 50
    assert_eq "$verb of a migrating bundle without room is rejected" "$(jq -r '.status' "$MSRES/$MSU.json" 2>/dev/null)" "rejected"
    assert_contains "…with the shared refusal" "$(jq -r '.error' "$MSRES/$MSU.json" 2>/dev/null)" "about 105 GiB free on /data (Tari's data.mdb plus a 5 GiB margin), and it has 50 GiB free"
    assert_contains "…saying the download was kept" "$(jq -r '.error' "$MSRES/$MSU.json" 2>/dev/null)" "The downloaded update was kept."
    assert_eq "…and keeping it staged for the retry" "$(ms_staged)" "present"
    assert_not_contains "…with no rauc install" "$(cat "$MS/rauc.log")" "install"
done
ms_verb os-verify 200
assert_eq "os-verify with room verifies" "$(jq -r '.status' "$MSRES/$MSU.json" 2>/dev/null)" "verified"
ms_verb os-install 200
assert_eq "os-install with room installs" "$(jq -r '.status' "$MSRES/$MSU.json" 2>/dev/null)" "installed"
assert_contains "…through rauc install" "$(cat "$MS/rauc.log")" "install $MSDIR/pithead-os-v2.0.0.raucb"
unset -f ms_env ms_guard ms_os_update ms_verb ms_staged
unset MS MSC MSRES MSDIR MSU MS_DF_ROOT verb out
