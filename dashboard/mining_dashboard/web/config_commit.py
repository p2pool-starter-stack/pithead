"""Typed payout confirmation for a sensitive Configuration-view commit."""


def approval_envelope(body):
    """Pass only typed payout suffixes to the host gate, which re-checks them against the staged
    config. This is the "retype the last characters of the new payout address" box — typo
    protection on an unrecoverable field, not a second identity (#2076)."""
    if body.get("approve") is not True:
        return None
    suffixes = body.get("payout_suffixes", {})
    if not isinstance(suffixes, dict) or any(
        key not in ("monero", "tari") or not isinstance(value, str)
        for key, value in suffixes.items()
    ):
        raise ValueError("invalid payout confirmation")
    return {"payout_suffixes": suffixes}
