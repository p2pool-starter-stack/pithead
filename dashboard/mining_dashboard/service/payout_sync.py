"""On-chain payout confirmation for both chains (#381, #462), and the poll-step guard (#1644).

Split out of ``data_service`` for a budget reason that is also a design one. ``data_service.py``
sits one line under its recorded ceiling, so the per-step ``try``/``except`` #1644 needs did not
fit inline; and these two steps are the only ones in the poll body proven independent enough to
isolate, which makes them a coherent thing to own rather than an arbitrary slice. Each step now
returns whether its wallet answered, for the faster wallet-health probe.

**What #1644 is about.** ``DataService.run()``'s poll body is 33 awaited steps under a single
``except Exception``, so any one of them raising skips every step below it for that poll. A
malformed body out of the Monero wallet took the Tari payout sync, the release check and the price
feed down with it — steps that have nothing to do with Monero payouts.

**Why only these two are guarded here.** ``_sync_payouts`` and ``_sync_tari_payouts`` take no poll
locals and write no ``self`` attribute: DB and alert side-effects only. Isolating them creates no
cross-iteration edge. That is NOT true of the rest of the body, and :func:`run_isolated` is
deliberately not applied more widely — the XvB block reads poll locals (``shares_list``,
``p2pool_stats``) sourced by earlier collectors and must keep skipping as a unit, and the remaining
steps have not been cleared. Widening this guard is a separate change that owes that clearing
first; a guard whose correctness nobody has established is worse than the skip it replaces,
because it looks like the work is done.
"""

import asyncio
import logging
import time

from mining_dashboard.config.config import MONERO_WALLET_ADDRESS, TARI_WALLET_ADDRESS

logger = logging.getLogger("DataService")


async def run_isolated(label, step):
    """Run one poll step so that its failure cannot skip the steps after it (#1644).

    The loop's own ``except Exception`` already keeps the service alive across a failed poll; what
    it cannot do is keep the REST OF THAT POLL running, because it sits at the bottom of the body.
    This is the same catch moved up to one step, so the poll continues past it.

    ``label`` names the step in the log. It is not cosmetic: the loop's handler logs one
    undifferentiated "Data Collection Error", and a step that now fails without ending the poll
    would otherwise be quieter than it was before it was guarded.
    """
    try:
        await step()
    except Exception as e:
        logger.error("Poll step failed, continuing with the rest of the poll — %s: %s", label, e)


async def sync_monero(state_manager, wallet_client, alert_service):
    """Confirm on-chain payouts from the view-only wallet-rpc (#381), throttled by the caller.

    Seeds the query from the highest stored Monero payout height, so a restart re-scans only
    the tip; ``add_payouts`` is idempotent on ``(chain, txid)``, so the overlap is dropped and
    nothing replays. Every genuinely-new confirmed payout fires exactly one ``payout_confirmed``
    alert. Returns whether the wallet RPC answered; an empty scan returns true and an RPC
    failure false. chain="monero" here; the Tari sibling (#462) reuses the same table."""
    chain = "monero"
    min_height = await asyncio.to_thread(state_manager.get_payout_max_height, chain)
    payouts, answered = await asyncio.to_thread(wallet_client.scan, min_height)
    if not answered or not payouts:
        return answered
    new_rows = await asyncio.to_thread(state_manager.add_payouts, chain, payouts)
    for r in new_rows:
        logger.info(
            "Payout confirmed on-chain: %.6f XMR (tx %s…) at height %d (#381)",
            r["amount_atomic"] / 1e12,
            r["txid"][:8],
            r["height"],
        )
        await alert_service.payout_confirmed_alert(chain, r["amount_atomic"], r["txid"])
    return answered


async def sync_tari(state_manager, tari_wallet_client, alert_service):
    """Confirm Tari on-chain payouts from the view-only console wallet (#462), throttled by the
    caller — the Tari sibling of :func:`sync_monero`.

    Identical shape: seed from the highest stored Tari payout height, stream new confirmed
    payouts, persist to the shared ``payouts`` table with chain="tari" (idempotent on
    ``(chain, txid)`` so a restart replays nothing), and fire one ``payout_confirmed`` alert per
    genuinely-new payout. ``amount_atomic`` is microTari here; the shared alert divides by the
    Tari divisor. The Tari client is async (grpc.aio), so it's awaited directly rather than via
    ``asyncio.to_thread``. Returns true for an empty answer and false for a failed RPC."""
    chain = "tari"
    min_height = await asyncio.to_thread(state_manager.get_payout_max_height, chain)
    payouts, answered = await tari_wallet_client.scan(min_height)
    if not answered or not payouts:
        return answered
    new_rows = await asyncio.to_thread(state_manager.add_payouts, chain, payouts)
    for r in new_rows:
        logger.info(
            "Tari payout confirmed on-chain: %.6f XTM (tx %s…) at height %d (#462)",
            r["amount_atomic"] / 1e6,
            r["txid"][:8],
            r["height"],
        )
        await alert_service.payout_confirmed_alert(chain, r["amount_atomic"], r["txid"])
    return answered


async def observe_wallet(
    chain, client, monitor, expected, previous, alert_service, scan_answered=None
):
    """Probe each cycle; payout scans remain on their slower cadence."""
    if chain == "tari":
        addresses, match = await client.payout_addresses(expected)
    else:
        addresses = await asyncio.to_thread(client.payout_addresses)
        match = expected in addresses if addresses is not None else None
    reachable = addresses is not None and scan_answered is not False
    bad = not reachable or not match
    was_down = monitor.down
    monitor.update(not bad)
    since = (previous or {}).get("since") if bad else None
    if bad and since is None:
        since = time.time()
    if monitor.down and not was_down:
        reason = (
            "unreachable" if not reachable else "address differs from configured payout address"
        )
        await alert_service.payout_wallet_down_alert(chain, reason)
    return {
        "reachable": reachable,
        "down": monitor.down,
        "since": since,
        "address_match": match,
        "configured_address": expected if match is False else None,
        "wallet_address": addresses[0] if match is False else None,
    }


async def observe_enabled_wallets(service):
    """Fast wallet checks run every data cycle, separately from the five-minute payout scan."""
    health = service.latest_data.setdefault("payout_wallet", {})
    for chain, client, monitor, expected, scan_answered in (
        (
            "monero",
            service.wallet_client,
            service.monero_wallet_health,
            MONERO_WALLET_ADDRESS,
            service.monero_wallet_scan_answered,
        ),
        (
            "tari",
            service.tari_wallet_client,
            service.tari_wallet_health,
            TARI_WALLET_ADDRESS,
            service.tari_wallet_scan_answered,
        ),
    ):
        if client is None:
            health.pop(chain, None)
            continue
        try:
            health[chain] = await observe_wallet(
                chain,
                client,
                monitor,
                expected,
                health.get(chain),
                service.alert_service,
                scan_answered,
            )
        except Exception as e:  # noqa: BLE001 — one wallet must not skip the other or the poll
            logger.error("%s payout wallet probe failed: %s", chain, e)
