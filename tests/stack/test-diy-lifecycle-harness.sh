# shellcheck shell=bash
: "${STACK_SUITE:?run tests/stack/run.sh}"
echo "== unit: DIY lifecycle harness (tests/diy) =="
DL="$SANDBOX/diy-lifecycle"
rm -rf "$DL"
mkdir -p "$DL/bin" "$DL/state"
export DIY_STATE_DIR="$DL/state" DIY_LOG_DIR="$DL/state/logs"
export DIY_REBOOT_MARKER="$DL/reboot-marker" DIY_BOOT_ID_FILE="$DL/boot_id"
printf 'boot-now\n' >"$DIY_BOOT_ID_FILE"
# shellcheck source=tests/diy/lifecycle.sh
source "$ROOT/tests/diy/lifecycle.sh"

tags=$'refs/tags/v1.19.1\nrefs/tags/v2.0.0-rc1\nrefs/tags/v2.0.0\nrefs/tags/v2.0.1\nrefs/tags/v2.0.2\nrefs/tags/v2.1.0\nrefs/tags/nightly'
assert_eq "previous tag is the highest release below VERSION" "$(diy_previous_tag 2.0.2 <<<"$tags")" "v2.0.1"
assert_eq "previous tag skips prereleases and unrelated tags" "$(diy_previous_tag 2.0.0 <<<"$tags")" "v1.19.1"
assert_eq "a prerelease VERSION resolves against its base" "$(diy_previous_tag 2.1.0-rc1 <<<"$tags")" "v2.0.2"
assert_eq "no earlier release gives no tag" "$(diy_previous_tag 1.0.0 <<<"$tags")" ""
assert_eq "bare tag names resolve like refs" "$(diy_previous_tag 2.0.2 <<<$'v2.0.0\nv2.0.1')" "v2.0.1"

out=$(
    DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
    diy_pass a fine
    diy_missing b later
    diy_summary
    echo "rc=$?"
)
assert_contains "pass and missing rows alone keep the exit status 0" "$out" "pass=1 fail=0 missing=1"
assert_contains "pass and missing rows alone keep the exit status 0 (rc)" "$out" "rc=0"
out=$(
    DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
    diy_fail c broken
    diy_summary
    echo "rc=$?"
)
assert_contains "one FAIL row fails the summary" "$out" "rc=1"
assert_contains "the FAIL row is machine readable" "$out" "LIFECYCLE-STEP c FAIL broken"

fail_step() {
    printf 'plain line\nDASHBOARD_PASSWORD=hunter2hunter2\nanother line\n'
    return 3
}
out=$(
    DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
    diy_step s "detail" fail_step
    echo "rc=$?"
)
assert_contains "a failing step prints a FAIL row" "$out" "LIFECYCLE-STEP s FAIL detail"
assert_contains "a failing step prints the tail of its log" "$out" "another line"
assert_not_contains "a failing step never prints a password line" "$out" "hunter2"
assert_contains "a failing step returns nonzero" "$out" "rc=1"

printf '#!/usr/bin/env bash\ncase "$1" in list-units) cat "$FAKE_UNITS" 2>/dev/null ;; list-unit-files) cat "$FAKE_UNIT_FILES" 2>/dev/null ;; esac\n' >"$DL/bin/systemctl"
printf '#!/usr/bin/env bash\ncase "$1" in ps) cat "$FAKE_DOCKER_PS" 2>/dev/null ;; images) cat "$FAKE_DOCKER_IMAGES" 2>/dev/null ;; volume) cat "$FAKE_DOCKER_VOLUMES" 2>/dev/null ;; esac\n' >"$DL/bin/docker"
printf '#!/usr/bin/env bash\ncat "$FAKE_IPTABLES" 2>/dev/null\n' >"$DL/bin/iptables"
printf '#!/usr/bin/env bash\ncat "$FAKE_NFT" 2>/dev/null\n' >"$DL/bin/nft"
chmod +x "$DL/bin/"*
residue() {
    PATH="$DL/bin:$PATH" FAKE_UNITS="$DL/units" FAKE_UNIT_FILES="$DL/unit-files" \
        FAKE_DOCKER_PS="$DL/ps" FAKE_DOCKER_IMAGES="$DL/images" FAKE_DOCKER_VOLUMES="$DL/volumes" \
        FAKE_IPTABLES="$DL/iptables" FAKE_NFT="$DL/nft" bash -c '
            source "$1"
            DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
            diy_assert_no_residue probe' _ "$ROOT/tests/diy/lib.sh"
}
rm -f "$DL"/units "$DL"/unit-files "$DL"/ps "$DL"/images "$DL"/volumes "$DL"/iptables "$DL"/nft
out=$(residue)
assert_contains "a clean guest has no systemd residue" "$out" "LIFECYCLE-STEP probe-systemd PASS"
assert_contains "a clean guest has no container or firewall residue" "$out" "LIFECYCLE-STEP probe-containers-firewall PASS"
printf 'pithead-egress.service not-found active exited Pithead egress\npithead-lan-check.service not-found failed failed LAN\n' >"$DL/units"
out=$(residue)
assert_contains "stale active and failed unit records are a systemd FAIL" "$out" "LIFECYCLE-STEP probe-systemd FAIL"
assert_contains "the stale record names the unit" "$out" "pithead-lan-check.service"
assert_contains "systemd residue does not fail the container row" "$out" "LIFECYCLE-STEP probe-containers-firewall PASS"
rm -f "$DL/units"
printf 'tari ghcr.io/example/tari\n' >"$DL/ps"
out=$(residue)
assert_contains "a leftover container is a container FAIL" "$out" "LIFECYCLE-STEP probe-containers-firewall FAIL"
rm -f "$DL/ps"
printf -- '-A DOCKER-USER -m comment --comment pithead-tor-egress -j DROP\n' >"$DL/iptables"
out=$(residue)
assert_contains "a leftover Pithead firewall rule is a FAIL" "$out" "LIFECYCLE-STEP probe-containers-firewall FAIL"
rm -f "$DL/iptables"
printf 'table inet pithead_lan\n' >"$DL/nft"
out=$(residue)
assert_contains "a leftover Pithead nft table is a FAIL" "$out" "LIFECYCLE-STEP probe-containers-firewall FAIL"
rm -f "$DL/nft"
printf 'ghcr.io/example/tari:v1\ndocker.io/library/caddy:2\n' >"$DIY_STATE_DIR/images.txt"
printf 'ghcr.io/example/tari:v1\nunrelated:1\n' >"$DL/images"
out=$(DIY_STATE_DIR="$DIY_STATE_DIR" residue)
assert_contains "a stack image that survives uninstall is a FAIL" "$out" "LIFECYCLE-STEP probe-containers-firewall FAIL"
assert_not_contains "an unrelated image is not residue" "$out" "unrelated:1"
rm -f "$DIY_STATE_DIR/images.txt" "$DL/images"

mkdir -p "$DL/kept/data"
printf 'a\n' >"$DL/kept/data/file"
d1=$(diy_tree_digest "$DL/kept")
assert_eq "an unchanged tree has a stable digest" "$(diy_tree_digest "$DL/kept")" "$d1"
printf 'b\n' >"$DL/kept/data/file"
if [ "$(diy_tree_digest "$DL/kept")" != "$d1" ]; then ok "a changed byte changes the digest"; else bad "a changed byte changes the digest" "digest unchanged"; fi
printf 'a\n' >"$DL/kept/data/file"
touch "$DL/kept/data/new"
if [ "$(diy_tree_digest "$DL/kept")" != "$d1" ]; then ok "a new file changes the digest"; else bad "a new file changes the digest" "digest unchanged"; fi

printf 'MONERO_RPC_PASSWORD=one\nPROXY_TOKEN=two\nOTHER=x\n' >"$DL/env1"
printf 'MONERO_RPC_PASSWORD=one\nPROXY_TOKEN=two\nOTHER=y\n' >"$DL/env2"
printf 'MONERO_RPC_PASSWORD=three\nPROXY_TOKEN=two\nOTHER=x\n' >"$DL/env3"
assert_eq "the secret fingerprint ignores non-secret keys" "$(diy_secret_fingerprint "$DL/env1")" "$(diy_secret_fingerprint "$DL/env2")"
if [ "$(diy_secret_fingerprint "$DL/env1")" != "$(diy_secret_fingerprint "$DL/env3")" ]; then ok "the secret fingerprint changes with a rotated secret"; else bad "the secret fingerprint changes with a rotated secret" "unchanged"; fi

printf '{"p2pool":{"pool":"mini"}}' >"$DL/c1"
printf '{"p2pool":{"pool":"nano"}}' >"$DL/c2"
printf '{}' >"$DL/c3"
assert_eq "apply moves mini to nano" "$(diy_other_pool "$DL/c1")" "nano"
assert_eq "apply moves nano to mini" "$(diy_other_pool "$DL/c2")" "mini"
assert_eq "an unset pool is mini, so apply picks nano" "$(diy_other_pool "$DL/c3")" "nano"

rm -f "$DIY_REBOOT_MARKER"
out=$(
    DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
    reboot_handoff
    echo "rc=$?"
)
assert_contains "no lane reboot marker: the reboot row is missing with the bench-ci pointer" "$out" "LIFECYCLE-STEP reboot-residue MISSING"
assert_contains "the missing reboot row points at the bench-ci issue" "$out" "bench-ci#2456"
assert_contains "a missing reboot row does not fail the run" "$out" "rc=0"
touch "$DIY_REBOOT_MARKER"
out=$(
    DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
    reboot_handoff
    echo "rc=$?"
)
assert_contains "with the lane marker the harness asks for the reboot with 75" "$out" "rc=75"
assert_eq "the boot id is recorded before the reboot" "$(cat "$DIY_STATE_DIR/boot-id")" "boot-now"
rm -f "$DIY_REBOOT_MARKER"

rm -f "$DIY_STATE_DIR/kept.digest"
out=$(
    DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
    after_reboot
)
assert_contains "after-reboot without first-session state fails" "$out" "LIFECYCLE-STEP after-reboot-state FAIL"

{
    mkdir -p "$DL/after"
    printf 'x\n' >"$DL/after/kept"
    printf '%s\n' "$DL/after/kept" >"$DIY_STATE_DIR/kept-paths"
    diy_tree_digest "$DL/after/kept" >"$DIY_STATE_DIR/kept.digest"
    cat "$DIY_BOOT_ID_FILE" >"$DIY_STATE_DIR/boot-id"
    out=$(
        PATH="$DL/bin:$PATH" DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
        after_reboot
    )
    assert_contains "the same boot id means no reboot happened" "$out" "LIFECYCLE-STEP after-reboot-booted FAIL"
    printf 'previous-boot\n' >"$DIY_STATE_DIR/boot-id"
    out=$(
        PATH="$DL/bin:$PATH" DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
        after_reboot
    )
    assert_contains "a different boot id passes the booted row" "$out" "LIFECYCLE-STEP after-reboot-booted PASS"
    assert_contains "residue is asserted again after the reboot" "$out" "LIFECYCLE-STEP reboot-systemd"
    assert_contains "kept data is compared after the reboot" "$out" "LIFECYCLE-STEP reboot-kept-data PASS"
    printf 'changed\n' >"$DL/after/kept"
    out=$(
        PATH="$DL/bin:$PATH" DIY_PASS=0 DIY_FAIL=0 DIY_MISSING=0
        after_reboot
    )
    assert_contains "kept data modified across the reboot fails" "$out" "LIFECYCLE-STEP reboot-kept-data FAIL"
}

cat >"$DL/prompts.sh" <<'EOS'
read -r -p "Enter Monero Wallet Address (primary — starts with 4): " w
read -r -p "Use LOCAL Monero node? (Y/n): " n
read -r -p "Merge-mine Tari? [2]: " t
read -r -p "Pool tier [mini]: " p
read -r -p "Start Pithead now? (Y/n): " s
printf '%s|%s|%s|%s|%s\n' "$w" "$n" "$t" "$p" "$s" >"$1"
exit 7
EOS
python3 -I "$ROOT/tests/diy/pty-answer.py" 4TESTWALLET 20 bash "$DL/prompts.sh" "$DL/answers.txt" >"$DL/pty.out" 2>&1
rc=$?
assert_rc "the pty driver returns the child's exit status" "$rc" 7
assert_eq "the pty driver answers the wallet, Tari 1, Enter defaults and n to the start prompt" "$(cat "$DL/answers.txt" 2>/dev/null)" "4TESTWALLET||1||n"
printf 'sleep 30\n' >"$DL/hang.sh"
python3 -I "$ROOT/tests/diy/pty-answer.py" 4TESTWALLET 2 bash "$DL/hang.sh" >/dev/null 2>&1
assert_rc "the pty driver times out a hung child" "$?" 124
