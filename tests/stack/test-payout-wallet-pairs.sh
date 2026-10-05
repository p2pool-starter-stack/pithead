# shellcheck shell=bash disable=SC2034
: "${STACK_SUITE:?source via tests/stack/run.sh}"
# Payout identities, matching keys and migration use the real CLI and entrypoints.
# shellcheck source=tests/integration/fixtures/payout-pairs.sh
source "$ROOT/tests/integration/fixtures/payout-pairs.sh"

echo "== payout wallets: matching keys, retained identities and legacy adoption =="

for chain in monero tari; do
    for k in 1 2; do
        pv="PAYOUT_VIEW$k" pub="PAYOUT_${chain^^}_PUBLIC$k"
        assert_eq "$chain public view key matches independent group vector $k" \
            "$(run_sourced "$SANDBOX" payout_public_view_key "$chain" "${!pv}")" "${!pub}"
    done
    assert_eq "$chain rejects a zero private scalar" "$(run_sourced "$SANDBOX" payout_public_view_key "$chain" "$(printf '%064d' 0)")" ""
done

build_val_sandbox
WALLET="$PAYOUT_MONERO1"
pair_config() {
    jq -n --arg m "$PAYOUT_MONERO1" --arg t "$PAYOUT_TARI1" --arg k "$PAYOUT_VIEW1" \
        '{monero:{mode:"local",wallet_address:$m,node_username:"u",node_password:"p",view_key:$k},
          tari:{wallet_address:$t,view_key:$k},p2pool:{pool:"main"},dashboard:{secure:true,host:"box.lan"}}' >"$V/config.json"
}
pair_apply() { (cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1); }
for chain in monero tari; do
    seed_env
    pair_config
    jq --arg c "$chain" --arg k "$PAYOUT_VIEW2" '.[$c].view_key=$k' "$V/config.json" >"$V/candidate"
    mv "$V/candidate" "$V/config.json"
    before="$(sha256sum "$V/.env")"
    out="$(pair_apply)"
    assert_rc "$chain apply refuses a wrong-wallet view key" "$?" 1
    assert_contains "$chain mismatch names both fields" "$out" "$chain.view_key does not belong to $chain.wallet_address"
    assert_eq "$chain mismatch preserves rendered config" "$(sha256sum "$V/.env")" "$before"
    assert_not_contains "$chain mismatch never prints the private key" "$out" "$PAYOUT_VIEW2"
done
seed_env
pair_config
out="$(pair_apply)"
assert_rc "both matching pairs apply with the Tari view key only" "$?" 0
assert_eq "Tari spend key derived in the secret file" \
    "$(sed -n 's/^MINOTARI_WALLET_SPEND_KEY=//p' "$V/data/tari-wallet-secret.env")" "$PAYOUT_TARI_PUBLIC1"
# The appliance's Tari wallet leg applies its own synthetic address and keys; they must pass.
leg="$ROOT/tests/os/appliance-tari-wallet-leg.sh"
leg_var() { sed -n "s/^$1=//p" "$leg"; }
pair_config
jq --arg t "$(leg_var TARI_WALLET_TEST_ADDRESS)" --arg k "$(leg_var TARI_WALLET_TEST_VIEW_KEY)" \
    --arg s "$(leg_var TARI_WALLET_TEST_SPEND_KEY)" \
    '.tari.wallet_address=$t | .tari.view_key=$k | .tari.spend_public_key=$s' "$V/config.json" >"$V/candidate"
mv "$V/candidate" "$V/config.json"
out="$(pair_apply)"
assert_rc "the appliance Tari wallet leg's address, view key and spend key apply" "$?" 0
pair_config
jq --arg s "$PAYOUT_TARI_PUBLIC2" '.tari.spend_public_key=$s' "$V/config.json" >"$V/candidate"
mv "$V/candidate" "$V/config.json"
out="$(pair_apply)"
assert_rc "explicit wrong Tari spend key is refused" "$?" 1
assert_contains "explicit spend mismatch names the field" "$out" 'tari.spend_public_key disagrees'
pair_config
jq --arg t "$VALID_TARI_SINGLE" '.tari.wallet_address=$t' "$V/config.json" >"$V/candidate"
mv "$V/candidate" "$V/config.json"
out="$(pair_apply)"
assert_rc "confirmation refuses a Tari single-key address" "$?" 1
assert_contains "single-key rejection explains Universe's dual-key address" "$out" 'dual-key address, which Tari Universe gives by default'
assert_contains "single-key rejection explains the missing public view key" "$out" 'no public view key'
jq 'del(.tari.view_key)' "$V/config.json" >"$V/candidate"
mv "$V/candidate" "$V/config.json"
out="$(pair_apply)"
assert_rc "single-key Tari mining remains accepted without confirmation" "$?" 0

pair_config
jq '.monero.payout_scan_height="123oops"' "$V/config.json" >"$V/candidate"
mv "$V/candidate" "$V/config.json"
out="$(pair_apply)"
assert_rc "Monero scan height rejects a numeric prefix followed by text" "$?" 1
assert_contains "invalid Monero height names the field" "$out" monero.payout_scan_height

# Exercise real startup with stub binaries, preserving each wallet's recorded progress.
PB="$SANDBOX/pair-bin" PD="$SANDBOX/pair-wallets"
mkdir -p "$PB" "$PD"
cat >"$PB/curl" <<'STUB'
#!/bin/sh
[ "${PAIR_NODE_DOWN:-0}" != 1 ] || exit 7
printf '{"result":{"count":3200100}}\n'
STUB
cat >"$PB/monero-wallet-rpc" <<'STUB'
#!/usr/bin/env bash
for ((i=1; i<=$#; i++)); do
    if [ "${!i}" = --generate-from-json ]; then
        i=$((i + 1)); file=$(jq -r .filename "${!i}")
        jq -r .scan_from_height "${!i}" >"$file"
        touch "$file.keys"
        echo create >"$PAIR_ACTION"
    elif [ "${!i}" = --wallet-file ]; then
        i=$((i + 1)); file="${!i}"; echo reopen >"$PAIR_ACTION"
    fi
done
printf '%s\n' "$file" >"$PAIR_PATH"
STUB
cat >"$PB/setpriv" <<'STUB'
#!/usr/bin/env bash
shift 3
exec "$@"
STUB
cat >"$PB/stat" <<'STUB'
#!/bin/sh
if [ "$2" = %u ]; then echo 1000; else exec /usr/bin/stat "$@"; fi
STUB
cat >"$PB/minotari_console_wallet" <<'STUB'
#!/usr/bin/env bash
while [ "$1" != --base-path ]; do shift; done
base="$2"; file="$base/mainnet/data/wallet/db/console_wallet.db"
if [ -f "$file" ]; then echo reopen >"$PAIR_ACTION"; else
    mkdir -p "$(dirname "$file")"; echo saved-progress >"$file"; echo create >"$PAIR_ACTION"
fi
printf '%s\n' "$file" >"$PAIR_PATH"
STUB
chmod +x "$PB/"*
pair_start() { # <chain> <pair> <volume>
    local c="$1" k="$2" d="$3" vk="PAYOUT_VIEW$2" addr="PAYOUT_${1^^}$2"
    mkdir -p "$d"
    if [ "$c" = monero ]; then
        PATH="$PB:$PATH" WALLET_DIR="$d" GEN_JSON="$d/gen.json" PAIR_ACTION="$PD/action" PAIR_PATH="$PD/path" \
            MONERO_WALLET_ADDRESS="${!addr}" MONERO_VIEW_KEY="${!vk}" PAYOUT_SCAN_HEIGHT=auto \
            bash "$ROOT/build/monero/wallet-entrypoint.sh" >/dev/null 2>&1
    else
        printf 'MINOTARI_WALLET_VIEW_PRIVATE_KEY=%s\nMINOTARI_WALLET_SPEND_KEY=%s\nMINOTARI_WALLET_PASSWORD=fixture\n' \
            "${!vk}" "$PAYOUT_TARI_PUBLIC1" >"$PD/secret"
        PATH="$PB:$PATH" WALLET_DIR="$d" TARI_WALLET_SECRET_FILE_IN="$PD/secret" TARI_WALLET_ADDRESS="${!addr}" \
            PAIR_ACTION="$PD/action" PAIR_PATH="$PD/path" bash "$ROOT/build/tari-wallet/entrypoint.sh" >/dev/null 2>&1
    fi
}
for chain in monero tari; do
    dir="$PD/$chain"
    pair_start "$chain" 1 "$dir"
    assert_rc "$chain first pair starts" "$?" 0
    first="$(cat "$PD/path")" first_inode="$(/usr/bin/stat -c %i "$(cat "$PD/path")")"
    assert_eq "$chain first pair creates" "$(cat "$PD/action")" create
    if [ "$chain" = monero ]; then assert_eq 'auto Monero starts 100 blocks behind tip' "$(cat "$first")" 3200000; fi
    touch -t 200001010000.00 "$dir/.payout-scanning"
    age="$(/usr/bin/stat -c %Y "$dir/.payout-scanning")"
    pair_start "$chain" 1 "$dir"
    assert_eq "$chain same-pair restart preserves scan grace age" "$(/usr/bin/stat -c %Y "$dir/.payout-scanning")" "$age"
    pair_start "$chain" 2 "$dir"
    assert_eq "$chain switching pairs starts new scan grace" "$([ "$(/usr/bin/stat -c %Y "$dir/.payout-scanning")" -gt "$age" ] && echo yes)" yes
    assert_eq "$chain changed pair creates a separate wallet" "$(cat "$PD/action")" create
    assert_eq "$chain old wallet kept" "$([ -f "$first" ] && echo yes)" yes
    pair_start "$chain" 1 "$dir"
    assert_eq "$chain revert reopens instead of creates" "$(cat "$PD/action")" reopen
    assert_eq "$chain revert retains the original inode" "$(/usr/bin/stat -c %i "$(cat "$PD/path")")" "$first_inode"
    assert_not_contains "$chain filename contains no view key" "$(cat "$PD/path")" "$PAYOUT_VIEW1"
    legacy="$PD/legacy-$chain"
    mkdir -p "$legacy"
    if [ "$chain" = monero ]; then
        printf 'saved-progress\n' >"$legacy/payout-wallet"
        touch "$legacy/payout-wallet.keys"
        old="$legacy/payout-wallet"
    else
        mkdir -p "$legacy/mainnet/data/wallet/db"
        old="$legacy/mainnet/data/wallet/db/console_wallet.db"
        printf 'saved-progress\n' >"$old"
    fi
    inode="$(/usr/bin/stat -c %i "$old")"
    pair_start "$chain" 1 "$legacy"
    assert_eq "$chain legacy adoption reopens" "$(cat "$PD/action")" reopen
    assert_eq "$chain legacy adoption keeps stored progress" "$(cat "$(cat "$PD/path")")" saved-progress
    assert_eq "$chain legacy adoption preserves inode" "$(/usr/bin/stat -c %i "$(cat "$PD/path")")" "$inode"
    pair_start "$chain" 2 "$legacy"
    assert_eq "$chain legacy adoption never applies to a second pair" "$(cat "$PD/action")" create
done
PAIR_NODE_DOWN=1 pair_start monero 1 "$PD/down"
assert_rc 'fresh auto wallet refuses an unavailable node without genesis fallback' "$?" 1

for field in MONERO_VIEW_KEY TARI_VIEW_KEY; do
    preview="$(run_sourced "$SANDBOX" describe_change "$field" "$PAYOUT_VIEW1" "$PAYOUT_VIEW2")"
    assert_contains "$field preview promises retained previous wallet" "$preview" 'a new view-only wallet is opened for this address (the previous one is kept)'
    assert_not_contains "$field preview no longer promises a rescan" "$preview" rescans
    assert_not_contains "$field preview hides the view key" "$preview" "$PAYOUT_VIEW2"
done

assert_eq "Monero explicit leading-zero height becomes valid JSON integer" \
    "$(PAYOUT_SCAN_HEIGHT=00042 PITHEAD_TEST_SOURCE=1 bash -c 'source "$1"; resolve_scan_height' _ "$ROOT/build/monero/wallet-entrypoint.sh")" 42
assert_eq "Monero explicit all-zero height becomes genesis zero" \
    "$(PAYOUT_SCAN_HEIGHT=000 PITHEAD_TEST_SOURCE=1 bash -c 'source "$1"; resolve_scan_height' _ "$ROOT/build/monero/wallet-entrypoint.sh")" 0
