"""New-install defaults based on disk measurements published by the host."""


def tari_disk_default(
    budget: dict, disks: list[dict], target: str, monero_mode: str, wipe: str = "keep"
) -> str:
    """Match the CLI: unknown capacity keeps local; insufficient capacity declines Tari."""
    available = budget.get("available_bytes")
    if disks:
        disk = next((d for d in disks if d["name"] == target), {})
        key = (
            "data_available_bytes"
            if disk.get("state") == "pithead-with-data" and wipe == "data"
            else "data_bytes"
        )
        available = disk.get(key)
    need = budget.get("remote_need_bytes" if monero_mode == "remote" else "local_need_bytes")
    if type(available) is int and type(need) is int:
        return "local" if available >= need else "off"
    return "local"


def fast_sync_warning(cfg: dict) -> str:
    networks = []
    for chain, name in (("monero", "Monero"), ("tari", "Tari")):
        section = cfg.get(chain)
        if isinstance(section, dict) and section.get("clearnet_initial_sync") is True:
            networks.append(f"the {name} network")
    if not networks:
        return ""
    return f"Fast sync exposes your IP address to {' and '.join(networks)} until the initial sync finishes."


def new_machine_answers(budget: dict, disks: list[dict]) -> dict:
    from mining_dashboard.wizard_config import NEW_MACHINE_ANSWERS, deep_merge

    return deep_merge(
        NEW_MACHINE_ANSWERS, {"tari": {"mode": tari_disk_default(budget, disks, "", "local")}}
    )


def explicit_wizard_config(cfg: dict, ref: dict) -> dict:
    from mining_dashboard.wizard_config import strip_defaults

    written = strip_defaults(cfg, ref) if ref else cfg
    # Wizard choices remain explicit even when they equal today's reference.
    for block, keys in (
        ("tari", ("mode", "clearnet_initial_sync")),
        ("monero", ("clearnet_initial_sync",)),
        ("xvb", ("enabled",)),
    ):
        for key in keys:
            if isinstance(cfg.get(block), dict) and key in cfg[block]:
                written.setdefault(block, {})[key] = cfg[block][key]
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
