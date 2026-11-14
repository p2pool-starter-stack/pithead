import re
from copy import deepcopy

from mining_dashboard.config.defaults import TABLE, effective_defaults

PROFILE_ORDER = ("balance", "performance", "privacy")
TARGET = "2.1.0"


def _split(path: str) -> list[str]:
    return path.split(".")


def _get(cfg: dict, path: str):
    value = cfg
    for key in _split(path):
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def _set(cfg: dict, path: str, value) -> None:
    *blocks, leaf = _split(path)
    node = cfg
    for key in blocks:
        if not isinstance(node.get(key), dict):
            node[key] = {}
        node = node[key]
    node[leaf] = value


def _version(stamp) -> tuple[int, int, int]:
    match = (
        re.fullmatch(r"(\d{1,4})\.(\d{1,4})\.(\d{1,4})", stamp) if isinstance(stamp, str) else None
    )
    return tuple(int(part) for part in match.groups()) if match else (2, 0, 0)


def migration_due(cfg: dict) -> bool:
    stamp = _version(cfg.get("config_version", "2.0.0"))
    profile = cfg.get("profile")
    return stamp < _version(TARGET) and (profile is None or profile is False)


def migrate_to_2_1(cfg: dict, platform: str = "diy") -> tuple[dict, list[str]]:
    rows = TABLE["profiles"]
    governed = list(rows["balance"])
    defaults = effective_defaults(platform)
    v2 = {
        entry["path"]: entry["value"]
        for entry in TABLE["migrations"][TARGET]["v2_absent"]
        if entry.get("platform", platform) == platform
    }

    def old(path):
        value = _get(cfg, path)
        if value is not None:
            return value
        return v2[path] if path in v2 else _get(defaults, path)

    def clash(path, name):
        row = rows[name][path]
        return old(path) == "" if row == "auto" else old(path) != row

    chosen = next(
        (name for name in PROFILE_ORDER if not any(clash(path, name) for path in governed)),
        "balance",
    )
    migrated = deepcopy(cfg)
    migrated["profile"] = chosen
    changes = [f"profile → {chosen}"]
    for path in sorted({*governed, *v2}):
        if _get(cfg, path) is not None:
            continue
        new = rows[chosen][path] if path in rows[chosen] else _get(defaults, path)
        if old(path) != new:
            _set(migrated, path, old(path))
            changes.append(f"{path} → pinned")
    return migrated, changes
