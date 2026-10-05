#!/usr/bin/env bash
# Produce the checked-in v1.20.0 restore fixture on a Docker-capable CI runner.
set -euo pipefail

out=${1:?usage: generate.sh OUTPUT_DIRECTORY|--wallets-only}

readonly TAG=v1.20.0
readonly BUNDLE_SHA256=77071195f5e8ef07b68a7bde9db20d30c0e64cfb561280d962d555acc03a6d4b
readonly COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign@sha256:4bedb8de1c5c1abd8dea60de704ba449402d238623fa8bb33d2ccaa9beffcbf5
readonly PASSPHRASE=v120-fixture-passphrase
repo=$(git rev-parse --show-toplevel)
wallets=$(
    python3 - "$repo/lib/pithead/25-address-types.sh" <<'PY'
import ctypes, ctypes.util, hashlib, json, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
code = source.split("import sys\n", 1)[1].split("\nPYEOF", 1)[0].rsplit("raw = b58_decode", 1)[0]
exec(code)
alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
width = {1: 2, 2: 3, 3: 5, 4: 6, 5: 7, 6: 9, 7: 10, 8: 11}
def encode(block):
    n, out = int.from_bytes(block, "big"), []
    for _ in range(width[len(block)]):
        n, remainder = divmod(n, 58)
        out.append(alpha[remainder])
    return "".join(reversed(out))
# Public throwaway seed: anyone can derive these test private keys. Never fund them.
seed = b"pithead v1.20.0 restore fixture / issue 3135 / throwaway keys"
library = ctypes.util.find_library("sodium")
if not library:
    raise RuntimeError("fixture generation requires libsodium")
sodium = ctypes.CDLL(library)
if sodium.sodium_init() < 0:
    raise RuntimeError("libsodium initialization failed")

def public_key(group, role):
    secret, public = ctypes.create_string_buffer(32), ctypes.create_string_buffer(32)
    digest = hashlib.sha512(seed + b"/" + group.encode() + b"/" + role.encode()).digest()
    getattr(sodium, "crypto_core_" + group + "_scalar_reduce")(secret, digest)
    operation = "crypto_scalarmult_" + group + "_base" + ("_noclamp" if group == "ed25519" else "")
    if getattr(sodium, operation)(public, secret) != 0:
        raise RuntimeError("fixture public-key derivation failed")
    return public.raw

raw = bytes([18]) + public_key("ed25519", "spend") + public_key("ed25519", "view")
raw += keccak256(raw)[:4]
monero = "".join(encode(raw[i : i + 8]) for i in range(0, len(raw), 8))
# Tari dual mainnet one-sided address: network, features, view + spend Ristretto keys, DammSum.
raw = bytes([0, 1]) + public_key("ristretto255", "view") + public_key("ristretto255", "spend")
tari_helpers = {}
exec(source.split("import os\n", 1)[1].split("\nPYEOF", 1)[0].split("try:\n", 1)[0], tari_helpers)
body = raw[2:] + bytes([tari_helpers["dammsum"](raw)])
n, encoded = int.from_bytes(body, "big"), ""
while n:
    n, digit = divmod(n, 58)
    encoded = alpha[digit] + encoded
encoded = "1" * (len(body) - len(body.lstrip(b"\0"))) + encoded
print(json.dumps({"monero": monero, "tari": "12" + encoded}))
PY
)

if [ "$out" = --wallets-only ]; then
    printf '%s\n' "$wallets"
    exit 0
fi
wallet=$(jq -r .monero <<<"$wallets")
tari_wallet=$(jq -r .tari <<<"$wallets")
work=$(mktemp -d)
trap 'sudo rm -rf "$work"' EXIT
mkdir -p "$out"
out=$(cd "$out" && pwd)
base="https://github.com/p2pool-starter-stack/pithead/releases/download/$TAG"
curl -fsSLo "$work/pithead.tar.gz" "$base/pithead.tar.gz"
curl -fsSLo "$work/pithead.tar.gz.sig" "$base/pithead.tar.gz.sig"
printf '%s  %s\n' "$BUNDLE_SHA256" "$work/pithead.tar.gz" | sha256sum -c -
chmod 755 "$work"
chmod 644 "$work/pithead.tar.gz" "$work/pithead.tar.gz.sig"
docker run --rm -e HOME=/tmp -v "$work:/artifact:ro" -v "$repo:/trust:ro" "$COSIGN_IMAGE" \
    verify-blob --key /trust/cosign.pub --signature /artifact/pithead.tar.gz.sig \
    --insecure-ignore-tlog=true /artifact/pithead.tar.gz >/dev/null
tar -xzf "$work/pithead.tar.gz" -C "$work"

cd "$work/pithead"
# xmrig_proxy.* and telegram.control are live v1.20.0 keys that 2.0.0 removed; the restore leg
# asserts they migrate or drop as docs/configuration.md documents. (dashboard.workers[] is not
# here: v1.20.0's own setup already moves a populated one to workers.list[].)
jq -n --arg wallet "$wallet" --arg tari "$tari_wallet" '{
  monero: {mode: "remote", wallet_address: $wallet, node_username: "fixture-rpc-user", node_password: "fixture-rpc-password", remote: {host: "10.0.0.1", rpc_port: 18081, zmq_port: 18083}},
  tari: {mode: "remote", wallet_address: $tari, remote: {host: "10.0.0.1", grpc_port: 18142}},
  p2pool: {pool: "mini", stratum_password: "fixture-stratum-password"},
  dashboard: {auth: {username: "fixture-admin", password: "fixture-dashboard-password"}, onion: {enabled: true, client_auth: true}, control: {enabled: true}, energy: {cost_per_kwh: 0.27, currency: "USD"}},
  xmrig_proxy: {enabled: true, url: "eu.xmrvsbeast.com:4247", donor_id: "fixture-donor"},
  telegram: {control: {enabled: false, allowed_ids: [], confirm_timeout: 60}}
}' >config.json
printf 'n\n' | ./pithead setup >/dev/null
# v1.20.0's Tor container creates its persisted paths as root.  The fixture owns
# only this disposable checkout, so hand it back before adding the chain sentinel.
sudo chown -R "$(id -u):$(id -g)" data
mkdir -p data/monero data/tari data/p2pool
printf 'v1.20.0 fixture chain data\n' >data/monero/chain-sentinel
PITHEAD_BACKUP_PASSPHRASE="$PASSPHRASE" ./pithead backup --with-chains --yes >/dev/null
install -m 600 backups/*.tar.gz.enc "$out/v1.20.0-backup.tar.gz.enc"
printf '%s\n' "$PASSPHRASE" >"$out/passphrase"
printf '%s\n' "$wallet" >"$out/wallet"
printf '%s\n' 'v1.20.0 signed compose bundle; sha256: 77071195f5e8ef07b68a7bde9db20d30c0e64cfb561280d962d555acc03a6d4b; signature verified against cosign.pub before extraction; disposable remote-node configuration; encrypted backup --with-chains; generated by tests/os/fixtures/v1.20.0/generate.sh' >"$out/PROVENANCE"
sha256sum "$out/v1.20.0-backup.tar.gz.enc" | awk '{print "encrypted archive sha256: " $1}' >>"$out/PROVENANCE"
printf '%s\n' 'Public throwaway seed: pithead v1.20.0 restore fixture / issue 3135 / throwaway keys; SHA512(seed/group/role) reduced to a scalar; Ed25519 spend/view and Ristretto255 view/spend public keys. Never fund these addresses.' >>"$out/PROVENANCE"
