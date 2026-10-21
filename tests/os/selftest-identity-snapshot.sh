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
bad() { :; }
before=$(_identity_snapshot)
_identity_unchanged fixture "$before"
for file in data/pithead/config.json data/pithead/.env data/tor/dashboard/hs_ed25519_secret_key data/tor/p2pool/hs_ed25519_public_key data/tor/p2pool/hostname etc/machine-id data/ssh/ssh_host_ed25519_key; do
    cp "$work/$file" "$work/original"
    printf '\nchanged\n' >>"$work/$file"
    if _identity_unchanged fixture "$before" 2>/dev/null; then
        echo "snapshot accepted changed $file" >&2
        exit 1
    fi
    cp "$work/original" "$work/$file"
    rm "$work/$file"
    if _identity_snapshot >/dev/null 2>&1; then
        echo "snapshot accepted missing $file" >&2
        exit 1
    fi
    mv "$work/original" "$work/$file"
done
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
_ssh() { printf 'config=%064d\n' 0; }
if _identity_snapshot >/dev/null; then exit 1; fi
printf 'identity-snapshot: PASS\n'
