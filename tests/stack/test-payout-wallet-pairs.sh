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
    if [ "$chain" = monero ]; then
        assert_contains "Monero mismatch names the secret view key" "$out" 'Use the secret (not public) view key of the wallet that owns this address'
    else
        assert_contains "Tari mismatch names the private view key" "$out" 'Use the private view key of the wallet that owns this address'
    fi
    assert_contains "$chain mismatch links the wallet guide" "$out" \
        "https://github.com/p2pool-starter-stack/pithead/blob/main/docs/dashboard.md#getting-your-view-keys"

    assert_eq "$chain mismatch preserves rendered config" "$(sha256sum "$V/.env")" "$before"
    assert_not_contains "$chain mismatch never prints the private key" "$out" "$PAYOUT_VIEW2"
done
# #3112: a malformed key names the standard wallet's own label and points at the docs section.
for pair in "monero:'Secret view key'" "tari:'view_private_key_hex' in config_wallet.json"; do
    chain=${pair%%:*}
    seed_env
    pair_config
    jq --arg c "$chain" '.[$c].view_key="not-a-view-key"' "$V/config.json" >"$V/candidate"
    mv "$V/candidate" "$V/config.json"
    out="$(pair_apply)"
    assert_rc "$chain apply refuses a malformed view key" "$?" 1
    assert_contains "$chain malformed-key message names the wallet label" "$out" "${pair#*:}"
    assert_contains "$chain malformed-key message points at the docs section" "$out" "https://github.com/p2pool-starter-stack/pithead/blob/main/docs/dashboard.md#getting-your-view-keys"
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
case "$*" in
    *18083/json_rpc*)
        for probe in "$WALLET_DIR"/.legacy-probe.*; do
            [ -f "$probe/identity" ] || continue
            jq -n --arg address "$(cat "$probe/identity")" '{result:{address:$address}}'
            exit 0
        done
        exit 7 ;;
    *GetCompleteAddress*)
        for probe in "$WALLET_DIR"/.legacy-probe.*; do
            [ -f "$probe/identity" ] || continue
            while [ "$1" != -o ]; do shift; done
            python3 - "$probe/identity" "$2" <<'PYFRAME'
import sys
from pathlib import Path
addr = Path(sys.argv[1]).read_bytes().strip()
body = bytes([34, len(addr)]) + addr
Path(sys.argv[2]).write_bytes(b'\0' + len(body).to_bytes(4, 'big') + body)
PYFRAME
            printf 'grpc-status: 0\r\n'
            exit 0
        done
        exit 7 ;;
esac
[ "${PAIR_NODE_DOWN:-0}" != 1 ] || exit 7
printf '{"result":{"count":3200100}}\n'
STUB
cat >"$PB/monero-wallet-rpc" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *--offline* ]]; then
    while [ "$1" != --wallet-file ]; do shift; done
    [ -s "$2.keys" ] || exit 1
    cp "$2.keys" "$(dirname "$2")/identity"
    exec sleep 60
fi
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
if [[ "$base" == */.legacy-probe.* ]]; then
    [ -z "${MINOTARI_WALLET_VIEW_PRIVATE_KEY:-}${MINOTARI_WALLET_SPEND_KEY:-}" ] || exit 1
    address=$(sed -n '2p' "$file")
    [ -n "$address" ] || exit 1
    printf '%s\n' "$address" >"$base/identity"
    exec sleep 60
fi
if [ -f "$file" ]; then echo reopen >"$PAIR_ACTION"; else
    mkdir -p "$(dirname "$file")"; echo saved-progress >"$file"; echo create >"$PAIR_ACTION"
fi
printf '%s\n' "$file" >"$PAIR_PATH"
STUB
cat >"$PB/chown" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$PB/"*
pair_start() { # <chain> <pair> <volume>
    local c="$1" k="$2" d="$3" vk="PAYOUT_VIEW$2" addr="PAYOUT_${1^^}$2"
    mkdir -p "$d"
    if [ "$c" = monero ]; then
        PATH="$PB:$PATH" WALLET_DIR="$d" GEN_JSON="$d/gen.json" PAIR_ACTION="$PD/action" PAIR_PATH="$PD/path" \
            MONERO_WALLET_ADDRESS="${!addr}" MONERO_VIEW_KEY="${!vk}" PAYOUT_SCAN_HEIGHT=auto \
            bash "$ROOT/build/monero/wallet-entrypoint.sh" >"$PD/start-output" 2>&1
    else
        printf 'MINOTARI_WALLET_VIEW_PRIVATE_KEY=%s\nMINOTARI_WALLET_SPEND_KEY=%s\nMINOTARI_WALLET_PASSWORD=fixture\n' \
            "${!vk}" "$PAYOUT_TARI_PUBLIC1" >"$PD/secret"
        PATH="$PB:$PATH" WALLET_DIR="$d" TARI_WALLET_SECRET_FILE_IN="$PD/secret" TARI_WALLET_ADDRESS="${!addr}" \
            PAIR_ACTION="$PD/action" PAIR_PATH="$PD/path" bash "$ROOT/build/tari-wallet/entrypoint.sh" >"$PD/start-output" 2>&1
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
        printf '%s\n' "$PAYOUT_MONERO1" >"$legacy/payout-wallet.keys"
        old="$legacy/payout-wallet"
    else
        mkdir -p "$legacy/mainnet/data/wallet/db"
        old="$legacy/mainnet/data/wallet/db/console_wallet.db"
        printf 'saved-progress\n%s\n' "$PAYOUT_TARI1" >"$old"
    fi
    inode="$(/usr/bin/stat -c %i "$old")"
    pair_start "$chain" 1 "$legacy"
    assert_eq "$chain legacy adoption reopens" "$(cat "$PD/action")" reopen
    assert_eq "$chain legacy adoption keeps stored progress" "$(head -n 1 "$(cat "$PD/path")")" saved-progress
    assert_eq "$chain legacy adoption preserves inode" "$(/usr/bin/stat -c %i "$(cat "$PD/path")")" "$inode"
    pair_start "$chain" 2 "$legacy"
    assert_eq "$chain legacy adoption never applies to a second pair" "$(cat "$PD/action")" create
    for state in changed unreadable; do
        legacy="$PD/$state-$chain"
        mkdir -p "$legacy"
        if [ "$chain" = monero ]; then
            old="$legacy/payout-wallet"
            printf 'saved-progress\n' >"$old"
            if [ "$state" = changed ]; then printf '%s\n' "$PAYOUT_MONERO1" >"$old.keys"; else touch "$old.keys"; fi
        else
            mkdir -p "$legacy/mainnet/data/wallet/db"
            old="$legacy/mainnet/data/wallet/db/console_wallet.db"
            printf 'saved-progress\n' >"$old"
            [ "$state" != changed ] || printf '%s\n' "$PAYOUT_TARI1" >>"$old"
        fi
        before=$(sha256sum "$old")
        pair_start "$chain" 2 "$legacy"
        assert_rc "$chain $state legacy identity starts the configured fresh pair" "$?" 0
        assert_eq "$chain $state legacy wallet remains byte-for-byte intact" "$(sha256sum "$old")" "$before"
        assert_eq "$chain $state legacy wallet is not stamped" "$([ ! -e "$legacy/.legacy-wallet-identity" ] && echo yes)" yes
        assert_not_contains "$chain $state diagnostic hides the view key" "$(cat "$PD/start-output")" "$PAYOUT_VIEW2"
        assert_contains "$chain $state diagnostic states refusal" "$(cat "$PD/start-output")" 'retaining it without adoption'
        assert_eq "$chain $state selects fresh-wallet creation" "$(cat "$PD/action")" create
        assert_eq "$chain $state probe storage is removed" "$(find "$legacy" -maxdepth 1 -name '.legacy-probe.*' | wc -l | tr -d ' ')" 0
    done
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

# Real parser: a matching substring, truncated frame or error is not an identity.
python3 - "$PD" "$PAYOUT_TARI1" <<'PYFRAME'
import sys
from pathlib import Path
root = Path(sys.argv[1])
address = sys.argv[2].encode()
body = bytes([34, len(address)]) + address
frame = b'\0' + len(body).to_bytes(4, 'big') + body
for name, data in {
    'valid': frame,
    'truncated': frame[:-1],
    'compressed': b'\1' + frame[1:],
    'trailing': frame + b'\0',
    'wrong-tag': frame[:5] + bytes([35]) + frame[6:],
    'empty': b'\0\0\0\0\0',
}.items():
    (root / ('response-' + name)).write_bytes(data)
PYFRAME
for state in valid truncated compressed trailing wrong-tag empty; do
    PITHEAD_TEST_SOURCE=1 bash -c 'source "$1"; legacy_response_matches "$2" "$3"' _ \
        "$ROOT/build/tari-wallet/entrypoint.sh" "$PD/response-$state" "$PAYOUT_TARI1"
    rc=$?
    expected=1
    [ "$state" != valid ] || expected=0
    assert_rc "Tari identity parser: $state" "$rc" "$expected"
done

# A setpriv child transitions from the wrapper uid to the wallet uid. Both windows must signal.
for phase in wrapper dropped; do
    for signal in -0 -KILL; do
        out=$(SIGNAL="$signal" PHASE="$phase" PITHEAD_TEST_SOURCE=1 bash -c '
            source "$1"
            kill() { [ "$PHASE" = wrapper ]; }
            setpriv() {
                [ "$1 $2 $3" = "--reuid=1000 --regid=1000 --clear-groups" ] || return 1
                shift 3
                [ "$1" = bash ] && [ "$5" = "$SIGNAL" ] && [ "$6" = 123 ] || return 1
                printf "child-uid\n"
            }
            legacy_probe_signal "$SIGNAL" 123 || exit $?
            printf "signalled\n"
        ' _ "$ROOT/build/tari-wallet/entrypoint.sh" 2>&1)
        assert_rc "Tari $phase uid can receive $signal" "$?" 0
        if [ "$phase" = wrapper ]; then
            assert_eq "Tari $signal before uid drop uses parent signal" "$out" signalled
        else
            assert_eq "Tari $signal after uid drop uses child uid signal" "$out" $'child-uid\nsignalled'
        fi
    done
done

python3 - "$PD/response-emoji" "$VALID_TARI_EMOJI" <<'PYFRAME'
import sys
from pathlib import Path
address = sys.argv[2].encode()
size = len(address)
body = bytes([42, (size & 127) | 128, size >> 7]) + address
Path(sys.argv[1]).write_bytes(b'\0' + len(body).to_bytes(4, 'big') + body)
PYFRAME
PITHEAD_TEST_SOURCE=1 bash -c 'source "$1"; legacy_response_matches "$2" "$3"' _ \
    "$ROOT/build/tari-wallet/entrypoint.sh" "$PD/response-emoji" "$VALID_TARI_EMOJI"
assert_rc 'Tari identity parser accepts the configured emoji representation' "$?" 0
