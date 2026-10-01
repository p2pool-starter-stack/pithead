"""Decode Tari payout addresses for key comparison with the wallet gRPC response."""

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

# The 256-emoji alphabet from tari's emoji.rs, index = byte value. Every entry is a single
# codepoint, and tari's own parser matches codepoints exactly — so exact .find() is faithful.
_EMOJI = (
    "🐢📟🌈🌊🎯🐋🌙🤔🌕⭐🎋🌰🌴🌵🌲🌸🌹🌻🌽🍀🍁🍄🥑🍆🍇🍈🍉🍊🍋🍌🍍🍎"
    "🍐🍑🍒🍓🍔🍕🍗🍚🍞🍟🥝🍣🍦🍩🍪🍫🍬🍭🍯🥐🍳🥄🍵🍶🍷🍸🍾🍺🍼🎀🎁🎂"
    "🎃🤖🎈🎉🎒🎓🎠🎡🎢🎣🎤🎥🎧🎨🎩🎪🎬🎭🎮🎰🎱🎲🎳🎵🎷🎸🎹🎺🎻🎼🎽🎾"
    "🎿🏀🏁🏆🏈⚽🏠🏥🏦🏭🏰🐀🐉🐊🐌🐍🦁🐐🐑🐔🙈🐗🐘🐙🐚🐛🐜🐝🐞🦋🐣🐨"
    "🦀🐪🐬🐭🐮🐯🐰🦆🦂🐴🐵🐶🐷🐸🐺🐻🐼🐽🐾👀👅👑👒🧢💅👕👖👗👘👙💃👛"
    "👞👟👠🥊👢👣🤡👻👽👾🤠👃💄💈💉💊💋👂💍💎💐💔🔒🧩💡💣💤💦💨💩➕💯"
    "💰💳💵💺💻💼📈📜📌📎📖📿📡⏰📱📷🔋🔌🚰🔑🔔🔥🔦🔧🔨🔩🔪🔫🔬🔭🔮🔱"
    "🗽😂😇😈🤑😍😎😱😷🤢👍👶🚀🚁🚂🚚🚑🚒🚓🛵🚗🚜🚢🚦🚧🚨🚪🚫🚲🚽🚿🧲"
)


def b58_decode(s):
    n = 0
    for ch in s:
        d = _B58.find(ch)
        if d < 0:
            return None
        n = n * 58 + d
    body = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\x00" * (len(s) - len(s.lstrip("1"))) + body


def address_key(raw):
    """Network/features and an optional payment ID do not change the payout key bytes."""
    if len(raw) == 35:
        return raw[:1] + raw[2:34]
    if 67 <= len(raw) <= 323:
        return raw[:1] + raw[2:66]
    return None


def decode_address(address):
    if address.isascii():
        if len(address) < 45:
            return None
        parts = [b58_decode(address[0]), b58_decode(address[1]), b58_decode(address[2:])]
        if any(part is None for part in parts):
            return None
        return b"".join(parts)
    raw = bytearray()
    for char in address:
        value = _EMOJI.find(char)
        if value < 0:
            return None
        raw.append(value)
    return bytes(raw)
