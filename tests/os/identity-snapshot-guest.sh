#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
root="${1:-}"
stack="$root/data/pithead"
cd "$stack"
for file in config.json .env "$root/etc/machine-id" "$root/data/ssh/ssh_host_ed25519_key"; do
    test -s "$file"
done
sha256sum config.json .env "$root/etc/machine-id" "$root/data/ssh/ssh_host_ed25519_key" |
    awk 'NR==1{print "config=" $1} NR==2{print "env=" $1} NR==3{print "machine=" $1} NR==4{print "ssh=" $1}'
python3 - <<'PY'
from hashlib import sha256
from pathlib import Path

lines = Path(".env").read_bytes().splitlines(keepends=True)
project = [line for line in lines if line.startswith(b"COMPOSE_PROJECT_NAME=")]
if len(project) > 1:
    raise SystemExit(1)
other = [line for line in lines if not line.startswith(b"COMPOSE_PROJECT_NAME=")]
print(f"env_project_present={len(project)}")
print(f"env_project={sha256(b''.join(project)).hexdigest()}")
print(f"env_other={sha256(b''.join(other)).hexdigest()}")
PY
wallets=$(jq -ce 'select(.monero.wallet_address | type == "string" and length > 0) | select(.tari.mode == "off" or (.tari.wallet_address | type == "string" and length > 0)) | [.monero.wallet_address, .tari.wallet_address]' config.json)
printf '%s\n' "$wallets" | sha256sum | awk '{print "wallet=" $1}'
tor=$(sed -n 's/^TOR_DATA_DIR=//p' .env)
case "$tor" in /*) ;; *) exit 1 ;; esac
test -d "$root$tor"
cd "$root$tor"
keys=$(find . -type f \( -name hs_ed25519_secret_key -o -name hs_ed25519_public_key -o -name hostname \) -exec dirname {} \; | sort -u)
test -n "$keys"
rows=""
while IFS= read -r key; do
    dir="$key"
    for file in hs_ed25519_secret_key hs_ed25519_public_key hostname; do
        test -s "$dir/$file"
        row=$(sha256sum "$dir/$file")
        rows="$rows$row
"
    done
done <<<"$keys"
printf '%s' "$rows" | sha256sum | awk '{print "tor=" $1}'
