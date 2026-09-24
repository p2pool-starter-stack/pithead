# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

# firstboot_consume_restore's rejections, continued from test-appliance-restore.sh on its fixture
# ($RS, $RSPOOL, $rarchive): every refused archive falls back to the form and touches nothing live.
# 2) Bad passphrase: rejected before anything is touched.
printf 'CORRUPTED\n' >"$RS/Caddyfile"
cp "$rarchive" "$RSPOOL/restore-archive" && printf 'not-the-passphrase' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" eval 'wizard_spool_clean_checked() { return 1; }; firstboot_consume_restore "$RSPOOL" || echo "rc$?"' 2>&1)
assert_contains "wrong passphrase rejected" "$out" "rc1"
assert_contains "private snapshot cleanup failure is visible" "$out" 'Could not clear every private restore snapshot'
assert_not_contains "private cleanup warning never reveals submitted content" "$out" not-the-passphrase
assert_contains "wrong passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "assphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$RS/Caddyfile")" "CORRUPTED"
assert_eq "the archive is consumed even on rejection" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained even on rejection" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
rm -f "$RSPOOL/error.txt"
printf 'snapshot-failure-secret' >"$RSPOOL/failed-pass"
out=$(run_sourced "$RS" eval 'wizard_spool_clean_checked() { return 1; }; head() { return 1; }; wizard_spool_snapshot "$RSPOOL" failed-pass || true' 2>&1)
assert_contains "failed private snapshot cleanup is visible" "$out" 'Could not clear a failed private wizard snapshot'
assert_not_contains "failed private snapshot cleanup never reveals content" "$out" snapshot-failure-secret

# 3) Encrypted archive, no passphrase supplied at all.
cp "$rarchive" "$RSPOOL/restore-archive"
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "missing passphrase rejected" "$out" "rc1"
assert_contains "missing passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "passphrase"
rm -f "$RSPOOL/error.txt"

# 4) Oversize: refused on SIZE alone, before any decrypt/extract — content is irrelevant.
truncate -s 67108865 "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "oversize archive rejected" "$out" "rc1"
assert_contains "oversize archive names the cap" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "too large"
rm -f "$RSPOOL/error.txt"

# 5) Malformed: neither the encrypted magic nor gzip's — falls back exactly like a rejected
# config, never blocking setup.
printf 'garbage-not-an-archive' >"$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "malformed archive rejected" "$out" "rc1"
assert_contains "malformed archive names the problem" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "not a Pithead backup archive"
assert_eq "malformed archive leaves config.json untouched" "$([ -f "$RS/config.json" ] || echo gone)" "gone"
rm -f "$RSPOOL/error.txt"

# 6) Path-traversal / symlink defense: a well-formed gzip archive (passes the magic + integrity
# checks) whose members escape the restore set must be refused BEFORE anything is staged to "/".
# A Pithead backup is only regular files under known prefixes, so a symlink or a ".." member is an
# attack. Built with real tar so the guard faces the exact bytes it would on a box.
MAL="$RS/mal"
mkdir -p "$MAL/pithead"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"     # live file the escape would try to clobber via symlink
ln -s /etc/shadow "$MAL/pithead/Caddyfile" # symlink escape
(cd "$MAL" && tar -czf "$RSPOOL/restore-archive" pithead) 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "a symlink member is refused" "$out" "rc1"
assert_contains "the symlink refusal names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "unsafe paths or links"
assert_eq "a symlink archive touches nothing" "$(cat "$RS/Caddyfile")" "CADDY-ORIG"
rm -f "$RSPOOL/error.txt" "$RSPOOL/restore-passphrase"

# Absolute-path member (stored with a leading slash via -P): would land at /… on cp -a.
printf 'EVIL\n' >"$MAL/evil"
(cd "$MAL" && tar -Pczf "$RSPOOL/restore-archive" "$MAL/evil") 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "an absolute-path member is refused" "$out" "rc1"
rm -f "$RSPOOL/error.txt"

# 7) Nothing to consume.
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$RS"
