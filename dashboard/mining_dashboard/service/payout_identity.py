import hashlib

from mining_dashboard.client.tari.address import address_key, decode_address
from mining_dashboard.config import config


def configured_wallet_id(chain: str) -> str | None:
    address = {
        "monero": config.MONERO_SUBADDRESS or config.MONERO_WALLET_ADDRESS,
        "tari": config.TARI_WALLET_ADDRESS,
    }[chain].strip()
    if not address:
        return None
    identity = address.encode("utf-8")
    if chain == "tari":
        raw = decode_address(address)
        key = address_key(raw) if raw else None
        if key is not None:
            identity = key
    return hashlib.sha256(chain.encode("ascii") + b"\x00" + identity).hexdigest()
