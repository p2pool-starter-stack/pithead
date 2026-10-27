import json
from copy import deepcopy
from pathlib import Path

TABLE = json.loads(Path(__file__).with_name("defaults.json").read_text())


def merge(base: dict, overrides: dict) -> dict:
    result = deepcopy(base)
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = deepcopy(value)
    return result


def effective_defaults(platform: str = "diy", *, legacy: bool = False) -> dict:
    if platform not in ("diy", "appliance"):
        raise ValueError("unknown configuration platform")
    result = merge(TABLE["values"], TABLE["appliance"] if platform == "appliance" else {})
    if legacy:
        for entry in TABLE["LEGACY_ABSENT"]:
            if entry.get("platform", platform) == platform:
                block, key = entry["path"].split(".")
                result[block][key] = entry["value"]
    return result


def default_of(path: str, platform: str = "diy", *, legacy: bool = False):
    value = effective_defaults(platform, legacy=legacy)
    for key in path.split("."):
        value = value[key]
    return value


def new_install_defaults(platform: str = "diy") -> dict:
    result = {}
    for path in TABLE["materialize"]:
        block, key = path.split(".")
        result.setdefault(block, {})[key] = default_of(path, platform)
    for chain in ("monero", "tari"):
        result.setdefault(chain, {})["clearnet_initial_sync"] = default_of(
            f"{chain}.clearnet_initial_sync", platform
        )
    return result
