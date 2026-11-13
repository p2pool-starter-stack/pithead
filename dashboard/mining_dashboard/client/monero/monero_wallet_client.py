import logging

import requests
from requests.auth import HTTPDigestAuth

from mining_dashboard.config.config import (
    MONERO_SUBADDRESS,
    MONERO_WALLET_ADDRESS,
    MONERO_WALLET_RPC_URL,
    WALLET_RPC_PASSWORD,
    WALLET_RPC_USERNAME,
)
from mining_dashboard.helper.http import bounded_request
from mining_dashboard.service.xvb.earnings import ATOMIC_PER_XMR

logger = logging.getLogger("MoneroWalletClient")


class MoneroWalletClient:
    """
    Reads confirmed incoming payouts from a view-only ``monero-wallet-rpc`` (#381).

    The stack runs monero-wallet-rpc generated from the operator's PRIVATE VIEW KEY (empty spend
    key) against the LOCAL monerod — it can SCAN but never spend. This client polls
    ``get_transfers {"in": true}`` on a slow cadence to confirm that P2Pool coinbase payouts
    actually landed in the wallet, the only ground truth (the earnings figure elsewhere is an
    estimate).

    monero-wallet-rpc runs with ``--rpc-login``, so calls use HTTP digest auth. Synchronous
    (requests + HTTPDigestAuth); the async data loop calls it via ``asyncio.to_thread``, mirroring
    :class:`MoneroClient`. Every failure mode returns ``None`` / ``[]`` so a wallet still doing its
    first-run scan (or briefly unreachable) degrades the feature quietly rather than raising.
    """

    def __init__(
        self,
        url=MONERO_WALLET_RPC_URL,
        username=WALLET_RPC_USERNAME,
        password=WALLET_RPC_PASSWORD,
        timeout=10,
        wallet_address=MONERO_WALLET_ADDRESS,
        subaddress=MONERO_SUBADDRESS,
    ):
        self.url = url
        # No creds → send unauthenticated; the request simply fails and the caller degrades.
        self._auth = HTTPDigestAuth(username, password) if username else None
        self.timeout = timeout
        self.wallet_address = wallet_address
        self.subaddress = subaddress

    def _rpc(self, method, params=None) -> dict | None:
        """POST one JSON-RPC call; return the ``result`` dict, or None on any error."""
        payload = {"jsonrpc": "2.0", "id": "0", "method": method, "params": params or {}}
        try:
            resp = bounded_request(
                "POST", self.url, json=payload, auth=self._auth, timeout=self.timeout
            )
        except requests.RequestException as e:
            logger.warning(f"wallet-rpc {method} unreachable at {self.url}: {e}")
            return None
        if resp.status_code != 200:
            logger.warning(f"wallet-rpc {method} returned HTTP {resp.status_code}")
            return None
        try:
            data = resp.json()
        except ValueError:
            logger.error(f"wallet-rpc {method} returned a non-JSON body")
            return None
        # A JSON body is not necessarily a JSON OBJECT. An array, string, number or null parses
        # cleanly and then dies below — at the membership test for a number or null, at the `.get`
        # for an array or string — a raise, where the docstring above promises None (#1592).
        if not isinstance(data, dict):
            logger.error(
                f"wallet-rpc {method} returned a JSON {type(data).__name__}, not an object"
            )
            return None
        # monero-wallet-rpc reports errors as a top-level "error" object, not an HTTP status.
        if "error" in data and data["error"]:
            logger.warning(f"wallet-rpc {method} error: {data['error']}")
            return None
        result = data.get("result")
        if result is None:
            return {}  # the call succeeded and carried no result — an empty answer, not an error.
        if not isinstance(result, dict):
            # A truthy non-dict `result` used to be handed straight back, escaping the annotation
            # above as a returned VALUE rather than as an exception — and then raising one level up
            # in `get_confirmed_payouts`, whose own docstring says it never raises (#1592).
            logger.warning(
                f"wallet-rpc {method} returned a {type(result).__name__} result, not an object"
            )
            return None
        return result

    def get_confirmed_payouts(self, min_height=0):
        return self.scan(min_height)[0]

    def _subaddress_index(self):
        result = self._rpc("get_address_index", {"address": self.subaddress})
        index = result.get("index") if result else None
        if not isinstance(index, dict):
            return None
        major, minor = index.get("major"), index.get("minor")
        if any(
            isinstance(value, bool) or not isinstance(value, int) or value < 0
            for value in (major, minor)
        ):
            return None
        return major, minor

    def scan(self, min_height=0):
        params = {
            "in": True,
            "coinbase": True,
            "filter_by_height": True,
            "min_height": int(min_height or 0),
        }
        if self.subaddress:
            primary = self._rpc("get_address")
            if not primary or primary.get("address") != self.wallet_address:
                return [], False
            index = self._subaddress_index()
            if index is None:
                return [], False
            params.update(account_index=index[0], subaddr_indices=[index[1]])
        result = self._rpc("get_transfers", params)
        if result is None:
            return [], False
        payouts = []
        # `in` is the wallet's word for its own payload shape, and the same "never raises" promise
        # covers it. A non-list `in` was iterated anyway — a dict yields its KEYS, a string its
        # CHARACTERS, and both then died at `.get` below; a number raised on the `for` itself
        # (#1592). Refuse the payload rather than the poll: `[]` is what every other failure here
        # returns, and the caller cannot distinguish it from "no payouts" in any case.
        rows = result.get("in") or []
        if not isinstance(rows, list):
            logger.warning(
                f"wallet-rpc get_transfers sent a {type(rows).__name__} 'in', not a list"
            )
            return [], False
        for t in rows:
            if not isinstance(t, dict):
                continue  # a non-object transfer is unusable — the same skip as the two below
            if self.subaddress and t.get("type") != "block":
                continue
            txid = t.get("txid")
            amount = t.get("amount")
            if not txid or amount is None:
                continue  # a transfer with no txid/amount is unusable — skip rather than store junk
            try:
                # A non-numeric or out-of-range field from a malformed reply would otherwise abort
                # the whole scan before min_height advances, re-fetching the poison every cycle. Skip
                # the bad transfer instead; the 64-bit bound also keeps add_payouts' INTEGER insert
                # from raising OverflowError. The local, authed monero-wallet-rpc always sends ints.
                amount_atomic = int(amount)
                height = int(t.get("height", 0) or 0)
                ts = float(t.get("timestamp", 0) or 0)
            except (ValueError, TypeError):
                continue
            if not 0 <= amount_atomic < 2**63:
                continue
            payouts.append(
                {
                    "txid": txid,
                    "height": height,
                    "ts": ts,
                    "amount_atomic": amount_atomic,
                    "amount_xmr": amount_atomic / ATOMIC_PER_XMR,
                }
            )
        return payouts, True

    def payout_addresses(self):
        result = self._rpc("get_address")
        if not result or not result.get("address"):
            return None
        primary = result["address"]
        if not self.subaddress:
            return [primary]
        if primary != self.wallet_address or self._subaddress_index() is None:
            return None
        return [primary, self.subaddress]
