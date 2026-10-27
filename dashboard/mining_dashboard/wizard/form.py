import secrets

from mining_dashboard.config.defaults import default_of
from mining_dashboard.wizard.defaults import automatic_setup_defaults


def build_config(
    form: dict, *, tari_default: str | None = None, platform: str = "appliance"
) -> dict:
    def s_(name: str) -> str:
        return str(form.get(name, "")).strip()

    def port(name: str, fallback: int) -> int:
        raw = s_(name)
        return int(raw) if raw.isdigit() else fallback

    cfg = automatic_setup_defaults(platform)
    cfg["dashboard"]["host"] = s_("machine_name") or default_of("dashboard.host", platform)
    cfg["monero"].update(
        {
            "wallet_address": s_("monero_wallet"),
            "mode": s_("monero_mode") or default_of("monero.mode", platform),
        }
    )
    cfg["p2pool"] = {
        "stratum_password": secrets.token_hex(12)
        if form.get("stratum_password") == "true"
        else default_of("p2pool.stratum_password", platform),
    }
    tari_mode = s_("tari_mode") or tari_default or default_of("tari.mode", platform)
    cfg["tari"]["mode"] = tari_mode
    if tari_mode != "off":
        cfg["tari"]["wallet_address"] = s_("tari_wallet")

    if form.get("monero_mode") == "remote":
        cfg["monero"]["mode"] = "remote"
        cfg["monero"]["remote"] = {
            "host": s_("monero_remote_host"),
            "rpc_port": port("monero_remote_rpc", default_of("monero.remote.rpc_port", platform)),
            "zmq_port": port("monero_remote_zmq", default_of("monero.remote.zmq_port", platform)),
        }
        if form.get("monero_remote_auth"):
            cfg["monero"]["node_username"] = s_("monero_remote_user")
            cfg["monero"]["node_password"] = s_("monero_remote_pass")

    if tari_mode == "remote":
        cfg["tari"]["remote"] = {
            "host": s_("tari_remote_host"),
            "grpc_port": port("tari_remote_grpc", default_of("tari.remote.grpc_port", platform)),
        }

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

    if form.get("role") in ("pithead", "both"):
        cfg["local_miner"]["enabled"] = form["role"] == "both"
    if "local_miner" in form:
        cfg["local_miner"]["enabled"] = str(form["local_miner"]).lower() in ("on", "true", "1")

    fast = form.get("clearnet_sync") == "true"
    cfg["monero"]["clearnet_initial_sync"] = fast and cfg["monero"]["mode"] == "local"
    cfg["tari"]["clearnet_initial_sync"] = fast and tari_mode == "local"

    tz = s_("timezone")
    if tz and tz != default_of("dashboard.timezone", platform):
        cfg.setdefault("dashboard", {})["timezone"] = tz

    return cfg
