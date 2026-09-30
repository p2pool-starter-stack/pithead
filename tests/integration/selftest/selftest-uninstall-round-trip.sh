#!/usr/bin/env bash
# The lifecycle phase's uninstall -> setup round trip (#2379) fails on any byte uninstall writes to
# kept data, on a derived path or volume it leaves, and on a setup that re-creates the chain.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

echo "== uninstall round trip: byte identity of kept data, removal of derived state (#2379) =="

extract() { sed -n "/^$1() {/,/^}$/p" "$HERE/../lib/run-lifecycle.sh"; }
eval "$(extract kept_data_snapshot_snippet)"
eval "$(extract kept_chain_files_snippet)"
eval "$(extract run_uninstall_round_trip)"
# shellcheck source=tests/integration/lib/run-lifecycle-wallet-fixture.sh
INTEGRATION_RUN_SUITE=1 source "$HERE/../lib/run-lifecycle-wallet-fixture.sh" || exit $?
# shellcheck disable=SC2034 # read by the extracted functions and rx
IT_MODE=local KEPT_SNAPSHOT_SUDO=""

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"compose up --no-deps --no-start tari-wallet")
    case "$FAKE_CASE" in
    no-wallet-seed)
        printf 'early detail\n'
        printf 'diagnostic %s\n' {1..20}
        printf 'PROXY_AUTH_TOKEN=leak\nPROXY_AUTH_TO\033[31mKEN=split-leak\nPROXY_AUTH_TO\033]0;title\007KEN=osc-leak\n\033[2J\rforged row\nimage unavailable\n' >&2
        exit 1 ;;
    no-wallet-seed-long)
        printf '%02500d\nfinal diagnostic\n' 0 >&2
        exit 1 ;;
    cleanup-list-error) exit 1 ;;
    esac
    grep -q 'tari_payout_confirm' .env || exit 1
    : >.created-volume
    : >.fake-volume
    case "$FAKE_CASE" in partial-wallet-seed | cleanup-inspect-error) exit 1 ;; esac
    : >.fake-container ;;
"compose rm -sf tari-wallet")
    [ -e .fake-container ] || exit 1
    rm .fake-container ;;
"compose --profile tari_payout_confirm rm -sf tari-wallet")
    [ "$FAKE_CASE" != owned-preexisting ] || exit 1
    rm -f .fake-container ;;
"container ls -a --format {{.Names}}")
    [ "$FAKE_CASE" != cleanup-list-error ] || exit 1
    [ ! -e .fake-container ] || echo tari-wallet ;;
"compose config --volumes")
    if grep -q 'tari_payout_confirm' .env; then echo tari_wallet_db; fi ;;
"volume create pithead_itest_unrelated_"*)
    : >.unrelated-volume
    printf '%s\n' "$3" >.unrelated-name
    echo "$3" ;;
"volume rm pithead_itest_unrelated_"*)
    rm -f .unrelated-volume .unrelated-name ;;
"volume rm pithead_tari_wallet_db")
    rm -f .fake-volume ;;
"volume inspect pithead_tari_wallet_db --format "*)
    if [ "$FAKE_CASE" = cleanup-inspect-error ] && [ -e .created-volume ]; then exit 1; fi
    [ -e .fake-volume ] || exit 1
    case "$FAKE_CASE" in
    wrong-wallet-label | foreign-preexisting) echo foreign/volume ;;
    *) echo pithead/tari_wallet_db ;;
    esac ;;
"volume ls -q")
    [ ! -e .fake-volume ] || echo pithead_tari_wallet_db
    [ ! -e .unrelated-volume ] || cat .unrelated-name ;;
esac
EOF
cat >"$T/fake-pithead" <<'EOF'
#!/usr/bin/env bash
case "$1" in
down) : >.stopped ;;
up) : >.restarted ;;
uninstall)
    : >.uninstalled
    # A stack still running when uninstall stops it writes its shutdown state into the chain dir.
    [ -e .stopped ] || printf x >>data/monero/p2pstate.bin
    printf 'Removed: x\nKept (yours): y\nLeft behind (shared with the machine): z\n  sudo rm -rf y\n'
    rm -rf .env data/control data/tari-wallet-secret.env
    case "$FAKE_CASE" in
    writes-small) printf x >>data/monero/p2pstate.bin ;;
    rewrites-big) printf x | dd of=data/monero/lmdb/data.mdb bs=1 seek=10 conv=notrunc 2>/dev/null ;;
    deletes-dir) rmdir data/tor/keys ;;
    leaves-secret) : >data/tari-wallet-secret.env ;;
    esac
    [ "$FAKE_CASE" = leaves-volume ] || rm -f .fake-volume
    [ "$FAKE_CASE" != removes-unrelated ] || rm -f .unrelated-volume
    ;;
setup)
    # The real setup refuses a deployed .env; the harness must hand back its secrets without the flag.
    ! grep -q '^DEPLOYMENT_COMPLETED=' .env && grep -q '^PROXY_AUTH_TOKEN=tok$' .env || exit 1
    cp .env.fixture .env
    [ "$FAKE_CASE" != resync ] || { rm data/monero/lmdb/data.mdb && truncate -s 70M data/monero/lmdb/data.mdb; }
    ;;
esac
EOF
chmod +x "$T/bin/docker" "$T/fake-pithead"
cat >"$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" != -n ] || shift
exec "$@"
EOF
chmod +x "$T/bin/sudo"
export PATH="$T/bin:$PATH"

drive() { # <case> -> round-trip-rc|failures
    (
        B="$T/box-$1"
        mkdir -p "$B/data/monero/lmdb" "$B/data/tor/keys" "$B/data/tor/monero" "$B/data/control" "$B/backups"
        printf 'abc.onion\n' >"$B/data/tor/monero/hostname"
        printf chain >"$B/data/monero/p2pstate.bin"
        truncate -s 70M "$B/data/monero/lmdb/data.mdb"
        printf '{}' >"$B/config.json"
        : >"$B/data/tari-wallet-secret.env"
        printf '%s\n' "MONERO_DATA_DIR=$B/data/monero" "TOR_DATA_DIR=$B/data/tor" "CONTROL_DIR=$B/data/control" \
            COMPOSE_PROFILES=local_node,local_tari MONERO_ONION_ADDRESS=abc.onion PROXY_AUTH_TOKEN=tok \
            DEPLOYMENT_COMPLETED=true >"$B/.env.fixture"
        cp "$B/.env.fixture" "$B/.env"
        case "$1" in
        owned-preexisting | foreign-preexisting) : >"$B/.fake-volume" ;;
        remote-tari) sed -i 's/COMPOSE_PROFILES=local_node,local_tari/COMPOSE_PROFILES=local_node/' "$B/.env" ;;
        esac
        [ "$1" != active-wallet-profile ] || sed -i 's/COMPOSE_PROFILES=local_node,local_tari/COMPOSE_PROFILES=local_node,local_tari,tari_payout_confirm/' "$B/.env"
        # shellcheck disable=SC2034 # read by rx and the extracted functions
        OUT_DIR="$B" IT_REMOTE_DIR="$B" IT_PITHEAD="$T/fake-pithead" IT_PASS=0 IT_FAIL=0
        export FAKE_CASE="$1"
        it_step() { :; }
        it_skip_leg() { printf '%s|%s|%s' "$1" "$2" "$3" >"$B/skip"; }
        wait_status_ok() { :; }
        env_on_box() { rx "grep -E '^$1=' .env 2>/dev/null | head -n1 | cut -d= -f2-"; }
        has_compose_profile() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac }
        upgrade_secret_fingerprints() {
            [ "$FAKE_CASE" != unreadable-secrets ] || return 1
            [ "$FAKE_CASE" != unreadable-after ] || [ ! -e "$B/.uninstalled" ] || return 1
            printf 'proxy=%064d\nonion-files=%064d\n' 1 2
        }
        [ "$1" != stale-onion-env ] || sed -i 's/abc.onion/old.onion/' "$B/.env"
        [ "$1" != missing-onion-file ] || rm "$B/data/tor/monero/hostname"
        run_uninstall_round_trip >"$B/run.log"
        result=$?
        if [ "$1" = clean ] || [ "$1" = stale-onion-env ]; then
            before_env="$(sed -n 's/^monero-env=//p' "$B/uninstall-before.secrets.txt")"
            before_key="$(sed -n 's/^monero-hostname=//p' "$B/uninstall-before.secrets.txt")"
            after_key="$(sed -n 's/^monero-hostname=//p' "$B/uninstall-after.secrets.txt")"
            [ -n "$before_key" ] && [ "$before_key" = "$after_key" ] || it_fail "diagnostics retain kept identity" "missing or changed digest"
            if [ "$1" = clean ]; then
                [ "$before_env" = "$before_key" ] || it_fail "matching rendered onion has matching digest" "digests differ"
            else
                [ "$before_env" != "$before_key" ] || it_fail "stale rendered onion has a distinct digest" "digests match"
            fi
            ! grep -Eq 'abc.onion|old.onion|tok' "$B"/uninstall-*.secrets.txt || it_fail "diagnostics contain no plaintext secrets" "secret leaked"
        fi
        if [ "$1" = no-wallet-seed ]; then
            grep -q 'image unavailable' "$B/run.log" &&
                ! grep -q 'early detail\|PROXY_AUTH_TOKEN=leak\|split-leak\|osc-leak' "$B/run.log" &&
                ! grep -q 'diagnostic 10 ' "$B/run.log" &&
                grep -q 'diagnostic 11 ' "$B/run.log" &&
                grep -q 'PROXY_AUTH_TOKEN=<redacted>' "$B/run.log" &&
                ! LC_ALL=C grep -q '[[:cntrl:]]' "$B/run.log" &&
                ! grep -q '^forged row' "$B/run.log" ||
                it_fail "Compose failure detail survives in the bounded row" "missing error"
        fi
        if [ "$1" = no-wallet-seed-long ]; then
            detail="$(grep 'compose up --no-start failed:' "$B/run.log")"
            [ "${#detail}" -le 2050 ] && [[ "$detail" = *'final diagnostic'* ]] ||
                it_fail "Compose failure detail is capped at 2000 characters" "detail too long or clipped at the wrong end"
        fi
        case "$1" in
        no-wallet-seed | no-wallet-seed-long | partial-wallet-seed | wrong-wallet-label | foreign-preexisting | active-wallet-profile)
            [ ! -e "$B/.uninstalled" ] || it_fail "bad fixture never reaches uninstall" "uninstall ran"
            [ -e "$B/.restarted" ] || it_fail "bad fixture restarts the stack" "up did not run"
            [ -e "$B/.env" ] || it_fail "bad fixture keeps .env" ".env was removed"
            ;;
        esac
        [ "$1" != wrong-wallet-label ] || [ -e "$B/.created-volume" ] || it_fail "wrong-label fixture reached Compose create" "create never ran"
        [ "$1" != foreign-preexisting ] || [ ! -e "$B/.created-volume" ] || it_fail "foreign preexisting volume is never recreated" "create ran"
        [ "$1" != owned-preexisting ] || [ -e "$B/.created-volume" ] || it_fail "owned preexisting volume was recreated by Compose" "create never ran"
        if [ "$1" = remote-tari ]; then
            [ ! -e "$B/.created-volume" ] && grep -q 'remote Tari mode:.*|by-design$' "$B/skip" ||
                it_fail "remote Tari mode skips the inapplicable wallet fixture" "wallet created or skip misclassified"
        fi
        [ "$1" != partial-wallet-seed ] || [ ! -e "$B/.fake-volume" ] || it_fail "partial Compose create cleanup removes its owned volume" "volume remains"
        printf '%s|%s' "$result" "$IT_FAIL"
    )
}

assert_eq "a clean uninstall and setup pass every row" "$(drive clean)" "0|0"
assert_eq "stale rendered onion is isolated without weakening identity assertion" "$(drive stale-onion-env)" "1|1"
assert_eq "unreadable categories fail before uninstall" "$(drive unreadable-secrets)" "1|1"
assert_eq "unreadable post-setup categories still fail the round trip" "$(drive unreadable-after)" "1|1"
assert_eq "missing kept hostname fails before uninstall" "$(drive missing-onion-file)" "1|1"
assert_eq "remote Tari mode skips wallet creation and still completes uninstall" "$(drive remote-tari)" "0|0"
assert_eq "a preexisting owned wallet volume is reset, then Compose creates it" "$(drive owned-preexisting)" "0|0"
assert_eq "failure to seed a wallet volume fails the pre-uninstall row" "$(drive no-wallet-seed)" "1|1"
assert_eq "long Compose errors are clipped at the end" "$(drive no-wallet-seed-long)" "1|1"
assert_eq "partial Compose create failure cleans its owned volume" "$(drive partial-wallet-seed)" "1|1"
assert_eq "cleanup reports a failed container listing" "$(drive cleanup-list-error)" "1|2"
assert_eq "cleanup reports a failed volume inspection" "$(drive cleanup-inspect-error)" "1|2"
assert_eq "a wallet volume with foreign labels fails the owned-volume precondition" "$(drive wrong-wallet-label)" "1|1"
assert_eq "a preexisting foreign wallet volume is never removed" "$(drive foreign-preexisting)" "1|1"
assert_eq "an active payout profile refuses the uninstall fixture" "$(drive active-wallet-profile)" "1|1"
assert_eq "one appended byte in a small kept file fails byte identity" "$(drive writes-small)" "1|1"
assert_eq "a same-size rewrite of a large chain file fails byte identity" "$(drive rewrites-big)" "1|1"
assert_eq "a removed kept directory fails byte identity" "$(drive deletes-dir)" "1|1"
assert_eq "a derived path left behind fails the removal row" "$(drive leaves-secret)" "1|1"
assert_eq "a named volume left behind fails the volume row" "$(drive leaves-volume)" "1|1"
assert_eq "removing an unrelated volume fails preservation" "$(drive removes-unrelated)" "1|1"
assert_eq "a setup that re-creates the chain file fails the reuse row" "$(drive resync)" "1|1"

# shellcheck disable=SC2034 # read by rx
IT_REMOTE_DIR="$T"
if rx "$(kept_data_snapshot_snippet "$T/no such path")" >/dev/null 2>&1; then
    it_fail "an unreadable kept path fails the snapshot, never prints an empty one"
else
    it_pass "an unreadable kept path fails the snapshot, never prints an empty one"
fi
mkdir -p "$T/q'uote d"
printf x >"$T/q'uote d/f"
assert_contains "a kept path with a space and a quote is hashed, not split" \
    "$(rx "$(kept_data_snapshot_snippet "$T/q'uote d")")" "q'uote d/f"

echo "selftest-uninstall-round-trip: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
