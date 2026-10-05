"""Check the fixture generator's deterministic, spendable throwaway public keys."""

# This selftest executes only repository-owned code and uses assertions as its verdict.
# ruff: noqa: S101, S102, S603

import ctypes
import ctypes.util
import json
import pathlib
import shutil
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("fixture selftest requires bash")
first = subprocess.check_output([BASH, str(HERE / "generate.sh"), "--wallets-only"])
assert first == subprocess.check_output([BASH, str(HERE / "generate.sh"), "--wallets-only"])
wallets = json.loads(first)
sodium = ctypes.CDLL(ctypes.util.find_library("sodium"))
assert sodium.sodium_init() >= 0

# Use the shipped checksum decoders, then independently validate both curve points.
source = (ROOT / "lib/pithead/25-address-types.sh").read_text()
namespace = {}
exec(
    source.split("import sys\n", 1)[1].split("\nPYEOF", 1)[0].rsplit("raw = b58_decode", 1)[0],
    namespace,
)
monero = namespace["b58_decode"](wallets["monero"])
assert monero[0] == 18 and len(monero) == 69
assert namespace["keccak256"](monero[:-4])[:4] == monero[-4:]
for key in (monero[1:33], monero[33:65]):
    assert sodium.crypto_core_ed25519_is_valid_point(key) == 1

tari_namespace = {}
exec(source.split("import os\n", 1)[1].split("\nPYEOF", 1)[0].split("try:\n", 1)[0], tari_namespace)
tari = wallets["tari"]
raw = b"".join(tari_namespace["b58_decode"](part) for part in (tari[0], tari[1], tari[2:]))
assert raw[:2] == bytes([0, 1]) and len(raw) == 67
assert tari_namespace["dammsum"](raw) == 0
for key in (raw[2:34], raw[34:66]):
    assert sodium.crypto_core_ristretto255_is_valid_point(key) == 1
print("fixture wallet determinism, checksums and four public keys: PASS")
