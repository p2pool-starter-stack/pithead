# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== black-box: administrative restore replaces SQLite file sets =="
build_backup_sandbox
RS="$SANDBOX/restore-sqlite"
RS_ROOT="$RS/roots"
RS_SRC="$RS_ROOT/${BK#/}"
mkdir -p "$RS_SRC/data/dashboard"
cp "$BK/config.json" "$BK/.env" "$BK/Caddyfile" "$RS_SRC/"
cat >"$BK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = chown ] && exit 0
exec "$@"
EOF
chmod +x "$BK/bin/sudo"

sqlite_base() {
    python3 - "$1" "$2" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA wal_autocheckpoint=0")
db.execute("CREATE TABLE evidence(value TEXT PRIMARY KEY)")
db.execute("INSERT INTO evidence VALUES (?)", (sys.argv[2],))
db.commit()
db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
db.close()
PY
}

sqlite_crash() {
    python3 - "$1" "$2" <<'PY'
import os
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA wal_autocheckpoint=0")
db.execute("INSERT INTO evidence VALUES (?)", (sys.argv[2],))
db.commit()
os._exit(0)
PY
}

sqlite_result() {
    python3 - "$1" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
rows = db.execute("SELECT group_concat(value, ',') FROM (SELECT value FROM evidence ORDER BY value)").fetchone()[0]
integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
print(f"{rows}|{integrity}")
db.close()
PY
}

sidecars() {
    local suffix
    for suffix in wal shm journal; do
        [ ! -e "$1-$suffix" ] || printf '%s ' "$suffix"
    done
}

reset_case() {
    rm -rf "$RS_SRC/data/dashboard" "$BK/data/dashboard"
    mkdir -p "$RS_SRC/data/dashboard" "$BK/data/dashboard"
    sqlite_base "$RS_SRC/data/dashboard/mining_data.db" "$1"
    cp "$RS_SRC/data/dashboard/mining_data.db" "$BK/data/dashboard/mining_data.db"
}

make_archive() {
    tar -czf "$1" -C "$RS_ROOT" \
        "${BK#/}/config.json" "${BK#/}/.env" "${BK#/}/Caddyfile" "${BK#/}/data/dashboard"
}

restore_archive() {
    local rc
    out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$1" 2>&1)"
    rc=$?
    printf '%s\n' "$out" >"$RS/restore.out"
    return "$rc"
}

reset_case archive
sqlite_crash "$BK/data/dashboard/mining_data.db" destination
printf 'stale\n' >"$BK/data/dashboard/mining_data.db-journal"
printf 'retain\n' >"$BK/data/dashboard/unrelated"
assert_eq "crashed destination fixture has WAL, SHM, and journal sidecars" \
    "$(sidecars "$BK/data/dashboard/mining_data.db")" "wal shm journal "
make_archive "$RS/clean-archive.tar.gz"
restore_archive "$RS/clean-archive.tar.gz"
assert_rc "clean archived database restores over a crashed destination" "$?" 0
assert_eq "destination-only SQLite sidecars are removed before the database opens" \
    "$(sidecars "$BK/data/dashboard/mining_data.db")" ""
assert_eq "destination WAL cannot override clean archived rows" \
    "$(sqlite_result "$BK/data/dashboard/mining_data.db")" "archive|ok"
assert_eq "database replacement retains unrelated destination files" \
    "$(cat "$BK/data/dashboard/unrelated")" retain

reset_case archive
rm -f "$BK/data/dashboard/mining_data.db"
sqlite_base "$BK/data/dashboard/mining_data.db" destination
make_archive "$RS/clean-control.tar.gz"
restore_archive "$RS/clean-control.tar.gz"
assert_rc "clean-sidecar control restores successfully" "$?" 0
assert_eq "clean-sidecar control restores archived rows" \
    "$(sqlite_result "$BK/data/dashboard/mining_data.db")" "archive|ok"

reset_case base
sqlite_crash "$BK/data/dashboard/mining_data.db" destination
sqlite_crash "$RS_SRC/data/dashboard/mining_data.db" archive
cp "$RS_SRC/data/dashboard/mining_data.db-wal" "$RS/archive.wal"
cp "$RS_SRC/data/dashboard/mining_data.db-shm" "$RS/archive.shm"
make_archive "$RS/archive-wal.tar.gz"
restore_archive "$RS/archive-wal.tar.gz"
assert_rc "archive-owned WAL restores over destination sidecars" "$?" 0
assert_eq "archive-owned sidecars exist before the database opens" \
    "$(sidecars "$BK/data/dashboard/mining_data.db")" "wal shm "
assert_rc "archived WAL bytes survive publication" \
    "$(
        cmp -s "$RS/archive.wal" "$BK/data/dashboard/mining_data.db-wal"
        echo $?
    )" 0
assert_rc "archived SHM bytes survive publication" \
    "$(
        cmp -s "$RS/archive.shm" "$BK/data/dashboard/mining_data.db-shm"
        echo $?
    )" 0
assert_eq "archive-owned WAL supplies the restored rows" \
    "$(sqlite_result "$BK/data/dashboard/mining_data.db")" "archive,base|ok"

reset_case base
sqlite_crash "$BK/data/dashboard/mining_data.db" destination
sqlite_crash "$RS_SRC/data/dashboard/mining_data.db" archive
cp "$RS_SRC/data/dashboard/mining_data.db-wal" "$RS/archive-no-shm.wal"
rm -f "$RS_SRC/data/dashboard/mining_data.db-shm"
make_archive "$RS/archive-wal-no-shm.tar.gz"
restore_archive "$RS/archive-wal-no-shm.tar.gz"
assert_rc "archive WAL without SHM restores successfully" "$?" 0
assert_eq "missing archived SHM does not retain the destination SHM" \
    "$(sidecars "$BK/data/dashboard/mining_data.db")" "wal "
assert_rc "unaccompanied archived WAL bytes survive publication" \
    "$(
        cmp -s "$RS/archive-no-shm.wal" "$BK/data/dashboard/mining_data.db-wal"
        echo $?
    )" 0
assert_eq "SQLite rebuilds SHM and reads the archived WAL" \
    "$(sqlite_result "$BK/data/dashboard/mining_data.db")" "archive,base|ok"

reset_case base
sqlite_crash "$BK/data/dashboard/mining_data.db" destination
printf 'retain\n' >"$BK/data/dashboard/unrelated"
rm -f "$RS_SRC/data/dashboard/mining_data.db"
printf 'archived unrelated\n' >"$RS_SRC/data/dashboard/archived-unrelated"
before_main=$(cksum "$BK/data/dashboard/mining_data.db")
before_wal=$(cksum "$BK/data/dashboard/mining_data.db-wal")
before_shm=$(cksum "$BK/data/dashboard/mining_data.db-shm")
make_archive "$RS/no-main.tar.gz"
restore_archive "$RS/no-main.tar.gz"
assert_rc "archive without a main database restores other files" "$?" 0
assert_eq "missing archived main leaves the destination main untouched" \
    "$(cksum "$BK/data/dashboard/mining_data.db")" "$before_main"
assert_eq "missing archived main leaves destination WAL untouched" \
    "$(cksum "$BK/data/dashboard/mining_data.db-wal")" "$before_wal"
assert_eq "missing archived main leaves destination SHM untouched" \
    "$(cksum "$BK/data/dashboard/mining_data.db-shm")" "$before_shm"
assert_eq "restore retains unrelated destination files" \
    "$(cat "$BK/data/dashboard/unrelated")" retain
assert_eq "restore still publishes unrelated archived files" \
    "$(cat "$BK/data/dashboard/archived-unrelated")" "archived unrelated"

reset_case archive
make_archive "$RS/removal-failure.tar.gz"
rm -f "$BK/data/dashboard/mining_data.db"
sqlite_base "$BK/data/dashboard/mining_data.db" destination
before_main=$(cksum "$BK/data/dashboard/mining_data.db")
mkdir "$BK/data/dashboard/mining_data.db-wal"
restore_archive "$RS/removal-failure.tar.gz"
assert_rc "sidecar removal failure aborts restore" "$?" 1
assert_eq "sidecar removal failure precedes database publication" \
    "$(cksum "$BK/data/dashboard/mining_data.db")" "$before_main"

rm -rf "$BK/data/dashboard" "$RS"
unset -f sqlite_base sqlite_crash sqlite_result sidecars reset_case make_archive restore_archive
unset RS RS_ROOT RS_SRC before_main before_wal before_shm out
