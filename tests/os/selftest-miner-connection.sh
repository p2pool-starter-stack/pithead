#!/usr/bin/env bash
# Pure host credential/target-carry regressions. No containers, guest or block devices.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# shellcheck source=lib/pithead/31a-miner-connection.sh
source "$root/lib/pithead/31a-miner-connection.sh"
# shellcheck source=lib/pithead/24-config-wizard.sh
source "$root/lib/pithead/24-config-wizard.sh"
export TEST_CARRY="$scratch/carry" TEST_TLS_DIR="$scratch/tls"
ENV_FILE="$scratch/.env" APP_UID=$(id -u) APP_GID=$(id -g)
restore_carry_dir() { printf '%s' "$TEST_CARRY"; }
env_get_file() { [ ! -f "$1" ] || sed -n "s/^$2=//p" "$1"; }
env_get() { env_get_file "$ENV_FILE" "$1"; }
# The child reads its candidate with the real helper; only directory derivation is stubbed.
parse_and_validate_config() { PROXY_TLS_DIR="$TEST_TLS_DIR"; }
export -f parse_and_validate_config
ensure_stratum_tls_cert() {
    [ -f "$PROXY_TLS_DIR/cert.pem" ] && return 0
    openssl req -x509 -newkey rsa:2048 -keyout "$PROXY_TLS_DIR/key.pem" \
        -out "$PROXY_TLS_DIR/cert.pem" -days 1 -nodes -subj /CN=fixture >/dev/null 2>&1
}
check() { if ! "$@"; then
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
fi; }
fail() { if "$@"; then
    printf 'FAIL: expected refusal\n' >&2
    exit 1
fi; }

wizard_ask_stratum_password </dev/null
check test "$WIZ_STRATUM_PASSWORD" = ""
wizard_ask_stratum_password <<<y
check test "${#WIZ_STRATUM_PASSWORD}" = 24
error() { return 1; }
fail_generation() (
    # shellcheck disable=SC2329 # invoked by wizard_ask_stratum_password
    openssl() { return 1; }
    wizard_ask_stratum_password <<<y
)
fail fail_generation

CONFIG_FILE="$scratch/written-config.json"
MONERO_MODE_WIZ=local IN_MONERO_WALLET=fixture-wallet IN_MONERO_USER=rpc IN_MONERO_PASS=fixture-rpc
TARI_MODE_WIZ=off POOL_TIER=mini IN_DASH_PASS="" CLEARNET_SYNC=false ONION_ENABLED=false TELEGRAM_BOT_TOKEN=""
wizard_write_config
check test "$(jq -r .p2pool.stratum_password "$CONFIG_FILE")" = "$WIZ_STRATUM_PASSWORD"
wizard_ask_stratum_password </dev/null
wizard_write_config
check test "$(jq -r .p2pool.stratum_password "$CONFIG_FILE")" = ""

candidate="$scratch/config.json"
printf '{"p2pool":{"stratum_password":"","stratum_tls":false}}' >"$candidate"
card=$(wizard_prepare_miner_connection "$candidate" 0)
check test "$(jq -r .stratum_password <<<"$card")" = ""
check test "$(jq -r .stratum_tls <<<"$card")" = false

printf '{"p2pool":{"stratum_password":"fixture-literal","stratum_tls":true}}' >"$candidate"
card=$(wizard_prepare_miner_connection "$candidate" 0)
check test "$(jq -r .stratum_password <<<"$card")" = fixture-literal
check test "${#card}" -gt 100
fp=$(jq -r .stratum_fingerprint <<<"$card")
check test "${#fp}" = 64
check test "$(wizard_prepare_miner_connection "$candidate" 0 | jq -r .stratum_fingerprint)" = "$fp"

printf '{"p2pool":{"stratum_password":"auto","stratum_tls":false}}' >"$candidate"
printf 'PROXY_STRATUM_PASSWORD=0123456789abcdef01234567\nOTHER=kept\n' >"$ENV_FILE"
card=$(wizard_prepare_miner_connection "$candidate" 0)
check test "$(jq -r .stratum_password <<<"$card")" = 0123456789abcdef01234567
check grep -qx OTHER=kept "$ENV_FILE"
check test "$(jq -r .p2pool.stratum_password "$candidate")" = auto
rm "$ENV_FILE"
card=$(wizard_prepare_miner_connection "$candidate" 0)
check test "$(env_get PROXY_STRATUM_PASSWORD)" = "$(jq -r .stratum_password <<<"$card")"

archive_env="$scratch/archive.env"
printf 'PROXY_STRATUM_PASSWORD=0123456789abcdef01234567\n' >"$archive_env"
restore_card_stratum_seed "$candidate" "$archive_env" "$candidate.stratum-password"
export TEST_TLS_DIR=/data/pithead/data/proxy-tls
card=$(wizard_prepare_miner_connection "$candidate" 1)
check test "$(jq -r .stratum_password <<<"$card")" = 0123456789abcdef01234567
check test ! -e "$candidate.stratum-password"
printf 'PROXY_STRATUM_PASSWORD=invalid\n' >"$archive_env"
fail restore_card_stratum_seed "$candidate" "$archive_env" "$scratch/seed"
printf 'PROXY_STRATUM_PASSWORD=0123456789abcdef01234567\nPROXY_STRATUM_PASSWORD=0123456789abcdef01234567\n' >"$archive_env"
fail restore_card_stratum_seed "$candidate" "$archive_env" "$scratch/seed"

# Simulate a mounted target in a private directory. The mount stub restores each fixture.
export TARGET_FIXTURE="$scratch/target" TEST_MOUNT_RECORD="$scratch/mounted"
mkdir -p "$TARGET_FIXTURE/pithead/data"
systemd-repart() { :; }
udevadm() { :; }
lsblk() { printf '/dev/fixture data\n'; }
mount() {
    local target="${!#}"
    cp -a "$TARGET_FIXTURE/." "$target/"
    printf '%s' "$target" >"$TEST_MOUNT_RECORD"
}
umount() {
    cp -a "$1/." "$TARGET_FIXTURE/"
    rm -rf "${1:?}"/*
}
export -f systemd-repart udevadm lsblk mount umount
printf '{"p2pool":{"stratum_password":"literal","stratum_tls":true}}' >"$candidate"
card=$(wizard_prepare_miner_connection "$candidate" 1)
install_miner_connection_to_target /dev/fixture
check test "$(cat "$TARGET_FIXTURE/pithead/.env")" = PROXY_STRATUM_PASSWORD=literal
check cmp "$TEST_CARRY/connection/tls/cert.pem" "$TARGET_FIXTURE/pithead/data/proxy-tls/cert.pem"
check cmp "$TEST_CARRY/connection/tls/key.pem" "$TARGET_FIXTURE/pithead/data/proxy-tls/key.pem"

# A keep-data install advertises and retains the existing target pair.
rm -rf "$TEST_CARRY/connection/tls"
wizard_retain_target_tls /dev/fixture /data/pithead/data/proxy-tls "$TEST_CARRY/connection/tls"
check cmp "$TEST_CARRY/connection/tls/cert.pem" "$TARGET_FIXTURE/pithead/data/proxy-tls/cert.pem"
jq '.target="fixture" | .wipe="keep"' "$TEST_CARRY/connection/state.json" >"$scratch/state"
mv "$scratch/state" "$TEST_CARRY/connection/state.json"
validate_miner_connection_install_request fixture keep
fail validate_miner_connection_install_request changed keep
fail validate_miner_connection_install_request fixture all

rm -rf "$TARGET_FIXTURE/pithead/data/proxy-tls"
ln -s "$scratch/outside" "$TARGET_FIXTURE/pithead/data/proxy-tls"
fail install_miner_connection_to_target /dev/fixture
rm "$TARGET_FIXTURE/pithead/data/proxy-tls"
jq '.tls_dir="/data/pithead/data/../escape"' "$TEST_CARRY/connection/state.json" >"$scratch/state"
mv "$scratch/state" "$TEST_CARRY/connection/state.json"
fail install_miner_connection_to_target /dev/fixture
jq '.tls_dir="/data/pithead/data/evil\nname/tls"' "$TEST_CARRY/connection/state.json" >"$scratch/state"
mv "$scratch/state" "$TEST_CARRY/connection/state.json"
fail install_miner_connection_to_target /dev/fixture
printf 'PASS: miner connection opt-in, preserved auto seed, TLS identity carry and hostile targets\n'
