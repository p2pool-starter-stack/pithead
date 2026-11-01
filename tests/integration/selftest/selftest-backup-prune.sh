#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/backup-prune.sh
source "$HERE/../lib/backup-prune.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkbackups() {
    local i
    rm -rf "$1" && mkdir -p "$1/.pithead-e2e-safety"
    for i in $(seq 1 "$2"); do
        local name
        name="$(printf 'pithead-backup-20260101-%06d.tar.gz' "$i")"
        : >"$1/$name"
        : >"$1/.pithead-e2e-safety/$name"
    done
    : >"$1/pithead-backup-20250101-000001.tar.gz.enc"
    : >"$1/pithead-backup-20240101-000001.tar.gz"
    : >"$1/pithead-backup-20240101-000002.tar.gz"
    : >"$1/notes.txt"
}
run() { bash -c "$1"; }
count() { printf '%s\n' "$1"/* | sed 's|.*/||' | grep -cE '^pithead-backup-[0-9]{8}-[0-9]{6}\.tar\.gz$'; }

echo "== backup_prune keeps the newest N =="
mkbackups "$T/b" 15
out="$(backup_prune run "$T/b" "$T/b/pithead-backup-20260101-000015.tar.gz")"
assert_eq "15 archives rotate down to 10" "$(count "$T/b")" "12"
assert_contains "the removed count is logged" "$out" "pruned 5 old safety backup(s)"
assert_eq "the newest survived" "$(test -f "$T/b/pithead-backup-20260101-000015.tar.gz" && echo y)" "y"
assert_eq "the oldest went" "$(test -e "$T/b/pithead-backup-20260101-000001.tar.gz" && echo y || echo n)" "n"
assert_eq "foreign names are untouched" "$(printf '%s\n' "$T/b"/* | sed 's|.*/||' | grep -vcE '^pithead-backup-[0-9]{8}-[0-9]{6}\.tar\.gz$')" "2"
assert_eq "unclassified manual archive survives" "$(test -f "$T/b/pithead-backup-20240101-000001.tar.gz" && echo y)" "y"
assert_eq "unclassified chain archive survives" "$(test -f "$T/b/pithead-backup-20240101-000002.tar.gz" && echo y)" "y"

echo "== only archives recorded by the harness rotate =="
mkbackups "$T/b" 15
rm "$T/b/.pithead-e2e-safety/pithead-backup-20260101-000015.tar.gz"
backup_prune run "$T/b" "$T/b/pithead-backup-20260101-000015.tar.gz" >/dev/null
assert_eq "the new archive is recorded" "$(test -f "$T/b/.pithead-e2e-safety/pithead-backup-20260101-000015.tar.gz" && echo y)" "y"
assert_eq "removed archives lose their record" "$(test -e "$T/b/.pithead-e2e-safety/pithead-backup-20260101-000001.tar.gz" && echo y || echo n)" "n"

echo "== a protected archive outside the newest N is kept =="
mkbackups "$T/b" 15
backup_prune run "$T/b" "$T/b/pithead-backup-20260101-000002.tar.gz" >/dev/null
assert_eq "the protected archive survived" "$(test -f "$T/b/pithead-backup-20260101-000002.tar.gz" && echo y)" "y"
assert_eq "N newest plus the protected one remain" "$(count "$T/b")" "13"

echo "== knobs =="
mkbackups "$T/b" 15
PITHEAD_E2E_BACKUP_KEEP=3 backup_prune run "$T/b" "$T/b/pithead-backup-20260101-000015.tar.gz" >/dev/null
assert_eq "KEEP=3 keeps three" "$(count "$T/b")" "5"
mkbackups "$T/b" 15
rm "$T/b/.pithead-e2e-safety/pithead-backup-20260101-000015.tar.gz"
PITHEAD_E2E_BACKUP_KEEP=0 backup_prune run "$T/b" "$T/b/pithead-backup-20260101-000015.tar.gz" >/dev/null
assert_eq "KEEP=0 disables pruning" "$(count "$T/b")" "17"
assert_eq "KEEP=0 still records the harness archive" "$(test -f "$T/b/.pithead-e2e-safety/pithead-backup-20260101-000015.tar.gz" && echo y)" "y"
PITHEAD_E2E_BACKUP_KEEP=abc backup_prune run "$T/b" "$T/b/pithead-backup-20260101-000015.tar.gz" >/dev/null
assert_eq "a non-number falls back to 10" "$(count "$T/b")" "12"

echo "== cleanup removes provenance and pruning failures are visible =="
mkbackups "$T/b" 1
(
    INTEGRATION_RUN_SUITE=1
    source "$HERE/../lib/run-safety.sh"
    SAFETY_ARCHIVE="$T/b/pithead-backup-20260101-000001.tar.gz" SAFETY_RESTORE_FAILED=0 KEEP_STATE=0
    rx() { bash -c "$1"; }
    safety_cleanup >/dev/null
)
assert_eq "safety cleanup removes the provenance marker" "$(test -e "$T/b/.pithead-e2e-safety/pithead-backup-20260101-000001.tar.gz" && echo y || echo n)" "n"
failed_prune() { return 1; }
assert_contains "failed pruning is reported without failing the harness" "$(backup_prune failed_prune "$T/b" "$T/b/pithead-backup-20260101-000001.tar.gz")" "safety backup pruning skipped (not fatal)"

echo "== a failed backup is never pruned =="
mkbackups "$T/b" 15
if (
    INTEGRATION_RUN_SUITE=1
    source "$HERE/../lib/run-safety.sh"
    SAFETY_BACKUP=1 RUN_IMAGE_UPGRADE=0 OUT_DIR="$T" SAFETY_ARCHIVE=""
    prune_calls=0
    pithead() { return 1; }
    it_fail() { :; }
    backup_prune() { prune_calls=$((prune_calls + 1)); }
    ! safety_backup && [ "$prune_calls" -eq 0 ]
); then
    it_pass "a failed backup never calls pruning"
else
    it_fail "a failed backup never calls pruning"
fi
assert_eq "run-safety prunes only after the archive is located" \
    "$(grep -B1 'backup_prune' "$HERE/../lib/run-safety.sh" | grep -c 'Safety backup: ')" "1"
assert_eq "run-lifecycle prunes only on the successful-backup path" \
    "$(grep -B3 'backup_prune' "$HERE/../lib/run-lifecycle.sh" | grep -c 'if backup_out=')" "1"
assert_eq "run-lifecycle protects the safety anchor" \
    "$(grep -c 'backup_prune rx backups "\$arch" "\${SAFETY_ARCHIVE:-}"' "$HERE/../lib/run-lifecycle.sh")" "1"
assert_eq "e2e backup_stack prunes only after the archive is located" \
    "$(sed -n '/^backup_stack() {$/,/^}$/p' "$HERE/../e2e.sh" | grep -A1 'ok "safety backup:' | tail -n1 | grep -c backup_prune)" "1"

printf '\nbackup-prune self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
