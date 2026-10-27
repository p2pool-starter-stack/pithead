from mining_dashboard.config.defaults import default_of, merge, new_install_defaults


def tari_disk_default(budget: dict, disks: list[dict], target: str, wipe: str = "keep") -> str:
    """Tari merge-mining is an opt-in beta (#3333): Enter means off, unless the disk being kept
    already holds a Tari chain, so a reinstall that keeps its data does not drop merge-mining.

    On the installation medium the target disk's layout decides: only the data-wipe option keeps
    the chains. A booted data disk reports its own chain size in the disk budget."""
    if disks:
        disk = next((d for d in disks if d["name"] == target), {})
        held = disk.get("state") == "pithead-with-data" and wipe == "data"
    else:
        held = budget.get("tari_chain_held") is True
    return "local" if held else default_of("tari.mode")


def fast_sync_warning(cfg: dict) -> str:
    networks = []
    for chain, name in (("monero", "Monero"), ("tari", "Tari")):
        section = cfg.get(chain)
        if isinstance(section, dict) and section.get("clearnet_initial_sync") is True:
            networks.append(f"the {name} network")
    if not networks:
        return ""
    return f"Fast sync exposes your IP address to {' and '.join(networks)} until the initial sync finishes."


def new_machine_answers(budget: dict, disks: list[dict], platform: str = "appliance") -> dict:
    return merge(
        new_install_defaults(platform), {"tari": {"mode": tari_disk_default(budget, disks, "")}}
    )


def explicit_wizard_config(cfg: dict, ref: dict) -> dict:
    from mining_dashboard.config.defaults import TABLE
    from mining_dashboard.wizard_config import strip_defaults

    written = strip_defaults(cfg, ref) if ref else cfg
    for path in TABLE["materialize"] + [
        "monero.clearnet_initial_sync",
        "tari.clearnet_initial_sync",
    ]:
        block, key = path.split(".")
        if isinstance(cfg.get(block), dict) and key in cfg[block]:
            written.setdefault(block, {})[key] = cfg[block][key]
    auth = cfg.get("dashboard", {}).get("auth")
    if isinstance(auth, dict) and auth.get("password") == "":
        written.setdefault("dashboard", {}).setdefault("auth", {})["password"] = ""
    return written


def disk_inventory(raw: str) -> list[dict]:
    """The host's inventory, as data. Parsing stays server-side so the client renders objects,
    never splits strings — and a model containing markup is just a JSON string to it."""
    out = []
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        name, size, model, serial, state = parts[:5]
        disk = {"name": name, "size": size, "model": model, "serial": serial, "state": state}
        if len(parts) > 5 and parts[5].isdigit():
            disk["data_bytes"] = int(parts[5])
        if len(parts) > 6 and parts[6].isdigit():
            disk["data_available_bytes"] = int(parts[6])
        out.append(disk)
    return out
