#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/data/pithead" "$work/data/tor/dashboard" "$work/data/tor/p2pool" "$work/data/ssh" "$work/etc"
printf '{"monero":{"wallet_address":"monero-fixture"},"tari":{"wallet_address":"tari-fixture"}}\n' >"$work/data/pithead/config.json"
printf 'TOR_DATA_DIR=/data/tor\nTOKEN=fixture\n' >"$work/data/pithead/.env"
printf 'machine-fixture\n' >"$work/etc/machine-id"
printf 'ssh-fixture\n' >"$work/data/ssh/ssh_host_ed25519_key"
for service in dashboard p2pool; do
    for name in hs_ed25519_secret_key hs_ed25519_public_key hostname; do
        printf '%s-%s-fixture\n' "$service" "$name" >"$work/data/tor/$service/$name"
    done
done
export SCRIPT_DIR="$HERE"
source "$HERE/lib/identity.sh"
_ssh() { bash -s -- "$work"; }
ok() { :; }
bad() { printf '%s\n' "$1"; }
before=$(_identity_snapshot)
if output=$(_identity_unchanged fixture ""); then exit 1; fi
[ "$output" = 'fixture: identity baseline is missing' ]
_identity_unchanged fixture "$before"
for file in data/pithead/config.json data/pithead/.env data/tor/dashboard/hs_ed25519_secret_key data/tor/p2pool/hs_ed25519_public_key data/tor/p2pool/hostname etc/machine-id data/ssh/ssh_host_ed25519_key; do
    cp "$work/$file" "$work/original"
    case "$file" in
    */config.json)
        expected="config"
        printf '\n' >>"$work/$file"
        ;;
    */.env)
        expected="env"
        printf '\nchanged\n' >>"$work/$file"
        ;;
    etc/*)
        expected="machine"
        printf '\nchanged\n' >>"$work/$file"
        ;;
    data/ssh/*)
        expected="ssh"
        printf '\nchanged\n' >>"$work/$file"
        ;;
    *)
        expected="tor"
        printf '\nchanged\n' >>"$work/$file"
        ;;
    esac
    if output=$(_identity_unchanged fixture "$before" 2>/dev/null); then
        echo "snapshot accepted changed $file" >&2
        exit 1
    fi
    [ "$output" = "fixture: identity changed ($expected)" ] || {
        echo "snapshot did not name changed category $expected" >&2
        exit 1
    }
    cp "$work/original" "$work/$file"
    rm "$work/$file"
    if _identity_snapshot >/dev/null 2>&1; then
        echo "snapshot accepted missing $file" >&2
        exit 1
    fi
    mv "$work/original" "$work/$file"
done
cp "$work/data/pithead/config.json" "$work/original"
jq '.monero.wallet_address = "changed-wallet-fixture"' "$work/original" >"$work/data/pithead/config.json"
if output=$(_identity_unchanged fixture "$before"); then exit 1; fi
[ "$output" = 'fixture: identity changed (config, wallet)' ]
mv "$work/original" "$work/data/pithead/config.json"
mkdir -p "$work/data/pithead/wizard/tls"
printf 'regenerated\n' >"$work/data/pithead/Caddyfile"
printf 'regenerated\n' >"$work/data/pithead/wizard/tls/cert.pem"
_identity_unchanged fixture "$before"
cp "$work/data/pithead/config.json" "$work/original"
printf '{"monero":{"wallet_address":"monero-fixture"},"tari":{"mode":"off"}}\n' >"$work/data/pithead/config.json"
_identity_snapshot >/dev/null
printf '{"monero":{"wallet_address":"monero-fixture"},"tari":{"mode":"local"}}\n' >"$work/data/pithead/config.json"
if _identity_snapshot >/dev/null 2>&1; then exit 1; fi
mv "$work/original" "$work/data/pithead/config.json"
_ssh() {
    printf 'config=%064d\n' 0
    return 1
}
if _identity_snapshot >/dev/null; then exit 1; fi
if output=$(_identity_unchanged fixture "$before"); then exit 1; fi
[ "$output" = 'fixture: identity snapshot could not be read' ]
_ssh() { printf 'config=%064d\n' 0; }
if _identity_snapshot >/dev/null; then exit 1; fi
printf 'identity-snapshot: PASS\n'
