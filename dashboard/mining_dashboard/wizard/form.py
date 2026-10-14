"""The no-JavaScript fallback for the first-boot wizard's setup form (#77 phase 3).

Split out of ``wizard.py`` so that file has room to grow (#1318): it sits at its
``docs/dev/file-budget.tsv`` ceiling, and ceilings only ever go down. This was the largest
self-contained thing in it — a pure mapping from form fields to a pithead config, with no module
state, no spool access and no request handling — so moving it whole changes nothing about how it
is reached. ``wizard.py`` re-imports the name, so ``wizard.build_config`` still resolves both for
the tests and for the one call site in ``submit``.
"""

import secrets


def build_config(form: dict, *, tari_default: str = "off") -> dict:
    """Form fields as a pithead config — the fallback for a client that never populated the
    JSON pane (no JavaScript: the harness's curl, a text browser). Mirrors the CLI wizard's
    question set; the host's parse_and_validate_config is the validator.

    Keys are omitted rather than written empty: an absent key inherits the documented default,
    while an empty string is a value and would override it."""

    def s_(name: str) -> str:
        return str(form.get(name, "")).strip()

    def port(name: str, fallback: int) -> int:
        raw = s_(name)
        return int(raw) if raw.isdigit() else fallback

    cfg: dict = {
        "dashboard": {"host": s_("machine_name") or "pithead"},
        "monero": {"wallet_address": s_("monero_wallet"), "mode": s_("monero_mode") or "local"},
        "xvb": {"enabled": False},
        "p2pool": {
            "pool": s_("pool") or "mini",
            "stratum_password": secrets.token_hex(12)
            if form.get("stratum_password") == "true"
            else "",
        },
    }

    # Explicit wizard answer, independent of the reference used by older configs.
    tari_mode = s_("tari_mode") or tari_default
    cfg["tari"] = {"mode": tari_mode}
    if tari_mode != "off":
        # A machine that does not merge-mine has nowhere to be paid, so the key is omitted
        # rather than sent empty. When it DOES merge-mine, an empty value still flows through
        # so the HOST produces the rejection, as it does for the Monero address.
        cfg["tari"]["wallet_address"] = s_("tari_wallet")
        # An opted-in beta Tari must not hold or reject Monero mining (#3333).
        cfg["dashboard"]["tari_required"] = False

    if form.get("monero_mode") == "remote":
        cfg["monero"]["mode"] = "remote"
        cfg["monero"]["remote"] = {
            "host": s_("monero_remote_host"),
            "rpc_port": port("monero_remote_rpc", 18081),
            "zmq_port": port("monero_remote_zmq", 18083),
        }
        if form.get("monero_remote_auth"):
            cfg["monero"]["node_username"] = s_("monero_remote_user")
            cfg["monero"]["node_password"] = s_("monero_remote_pass")

    if tari_mode == "remote":
        cfg["tari"]["remote"] = {
            "host": s_("tari_remote_host"),
            "grpc_port": port("tari_remote_grpc", 18142),
        }

    # prune only means anything for a node we run. On remote, the key is noise at best and a
    # lie at worst — the chain lives on someone else's machine and its shape is not ours.
    if form.get("monero_mode") != "remote" and form.get("prune") == "false":
        cfg["monero"]["prune"] = False

    # Optional services: written ONLY when actually filled in. An empty ping_url silently
    # disables the dead-man's switch the operator thinks they have; a half-configured
    # Telegram fails validation on a blank they never meant to set.
    hc = s_("healthchecks_url")
    if hc:
        cfg["healthchecks"] = {"ping_url": hc}
    tg_token, tg_chat = s_("telegram_token"), s_("telegram_chat")
    if tg_token and tg_chat:
        cfg["telegram"] = {"enabled": True, "bot_token": tg_token, "chat_id": tg_chat}

    if form.get("local_miner"):
        cfg["local_miner"] = {"enabled": True}

    fast = form.get("clearnet_sync") == "true"
    cfg["monero"]["clearnet_initial_sync"] = fast and cfg["monero"]["mode"] == "local"
    cfg["tari"]["clearnet_initial_sync"] = fast and tari_mode == "local"

    tz = s_("timezone")
    if tz and tz != "auto":  # auto IS the documented default — writing it would only pin it
        cfg.setdefault("dashboard", {})["timezone"] = tz

    return cfg
