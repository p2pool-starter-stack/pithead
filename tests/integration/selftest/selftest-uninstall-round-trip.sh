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
# shellcheck disable=SC2034 # read by the extracted functions and rx
IT_MODE=local KEPT_SNAPSHOT_SUDO=""

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$*" != "volume ls -q" ] || { [ ! -e .fake-volume ] || echo pithead_tari_wallet_data; }
EOF
cat >"$T/fake-pithead" <<'EOF'
#!/usr/bin/env bash
case "$1" in
down) : >.stopped ;;
uninstall)
    # A stack still running when uninstall stops it writes its shutdown state into the chain dir.
    [ -e .stopped ] || printf x >>data/monero/p2pstate.bin
    printf 'Removed: x\nKept (yours): y\nLeft behind (shared with the machine): z\n  sudo rm -rf y\n'
    rm -rf .env data/control data/tari-wallet-secret.env
    case "$FAKE_CASE" in
    writes-small) printf x >>data/monero/p2pstate.bin ;;
    rewrites-big) printf x | dd of=data/monero/lmdb/data.mdb bs=1 seek=10 conv=notrunc 2>/dev/null ;;
    deletes-dir) rmdir data/tor/keys ;;
    leaves-secret) : >data/tari-wallet-secret.env ;;
    leaves-volume) : >.fake-volume ;;
    esac
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
export PATH="$T/bin:$PATH"

drive() { # <case> -> round-trip-rc|failures
    (
        B="$T/box-$1"
        mkdir -p "$B/data/monero/lmdb" "$B/data/tor/keys" "$B/data/control" "$B/backups"
        printf chain >"$B/data/monero/p2pstate.bin"
        truncate -s 70M "$B/data/monero/lmdb/data.mdb"
        printf '{}' >"$B/config.json"
        : >"$B/data/tari-wallet-secret.env"
        printf '%s\n' "MONERO_DATA_DIR=$B/data/monero" "TOR_DATA_DIR=$B/data/tor" "CONTROL_DIR=$B/data/control" \
            COMPOSE_PROFILES=local_node MONERO_ONION_ADDRESS=abc.onion PROXY_AUTH_TOKEN=tok \
            DEPLOYMENT_COMPLETED=true >"$B/.env.fixture"
        cp "$B/.env.fixture" "$B/.env"
        # shellcheck disable=SC2034 # read by rx and the extracted functions
        IT_REMOTE_DIR="$B" IT_PITHEAD="$T/fake-pithead" IT_PASS=0 IT_FAIL=0
        export FAKE_CASE="$1"
        it_step() { :; }
        it_skip_leg() { :; }
        wait_status_ok() { :; }
        env_on_box() { rx "grep -E '^$1=' .env 2>/dev/null | head -n1 | cut -d= -f2-"; }
        has_compose_profile() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac }
        run_uninstall_round_trip >/dev/null
        printf '%s|%s' "$?" "$IT_FAIL"
    )
}

assert_eq "a clean uninstall and setup pass every row" "$(drive clean)" "0|0"
assert_eq "one appended byte in a small kept file fails byte identity" "$(drive writes-small)" "1|1"
assert_eq "a same-size rewrite of a large chain file fails byte identity" "$(drive rewrites-big)" "1|1"
assert_eq "a removed kept directory fails byte identity" "$(drive deletes-dir)" "1|1"
assert_eq "a derived path left behind fails the removal row" "$(drive leaves-secret)" "1|1"
assert_eq "a named volume left behind fails the volume row" "$(drive leaves-volume)" "1|1"
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
