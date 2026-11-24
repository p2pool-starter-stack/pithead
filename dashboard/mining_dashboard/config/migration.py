import re
from copy import deepcopy

from mining_dashboard.config.defaults import TABLE, effective_defaults
from mining_dashboard.service.notify.alert_levels import ALL_EVENTS, LEVEL_EVENTS

PROFILE_ORDER = ("balance", "performance", "privacy")
TARGET = "2.1.0"
PROFILE_NEW_KEYS = frozenset({"donation.tor"})


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
        if path in PROFILE_NEW_KEYS and _get(cfg, path) is None:
            return False
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
        if _get(cfg, path) is not None or path in PROFILE_NEW_KEYS:
            continue
        new = rows[chosen][path] if path in rows[chosen] else _get(defaults, path)
        if old(path) != new:
            _set(migrated, path, old(path))
            changes.append(f"{path} → pinned")
    return migrated, changes


def migrate_telegram_level(cfg: dict) -> tuple[dict, list[str]]:
    telegram = cfg.get("telegram")
    if not isinstance(telegram, dict) or not ({"enabled", "events"} & telegram.keys()):
        return cfg, []
    events = telegram.get("events") if isinstance(telegram.get("events"), dict) else {}
    sending = (
        str(telegram.get("bot_token") or "").strip() != ""
        and str(telegram.get("chat_id") or "").strip() != ""
        and str(telegram.get("enabled", False)).lower() == "true"
    )
    old = {e for e in ALL_EVENTS if events.get(e) is not False} if sending else set()
    best = min(
        ("all", "important", "critical", "off"),
        key=lambda name: len(LEVEL_EVENTS[name] ^ old),
    )
    migrated = deepcopy(cfg)
    migrated["telegram"].pop("enabled", None)
    migrated["telegram"].pop("events", None)
    level = telegram.get("level") or best
    migrated["telegram"]["level"] = level
    return migrated, [f"telegram.level → {level}"]
