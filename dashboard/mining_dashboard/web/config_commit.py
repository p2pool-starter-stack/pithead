"""Typed payout confirmation for a sensitive Configuration-view commit."""

from aiohttp import web

from mining_dashboard.config import documents


async def config_request(request):
    """Check the raw control body before decoding can hide duplicates or staging an intent."""
    try:
        body = await request.json(loads=documents.loads)
        if not isinstance(body, dict):
            raise web.HTTPBadRequest(text="Body must be a JSON object.")
        if "config" in body:
            documents.reject_placeholders(body["config"])
    except documents.ConfigDocumentError as exc:
        raise web.HTTPBadRequest(text=exc.diagnostic()) from None
    except web.HTTPBadRequest:
        raise
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    return body


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
