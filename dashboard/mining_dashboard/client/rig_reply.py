from mining_dashboard.helper.utils import finite_number, plausible_rate, safe_text

_TEXT_MAX = 1024
_NUMBER_MAX = 2**63 - 1
_DEPTH_MAX = 16


def _flag(value):
    return value if isinstance(value, bool) else None


def _text(limit):
    return lambda value: safe_text(value, limit)


def _clipped(limit):
    def clip(value):
        if not isinstance(value, str):
            return None
        return "".join(char if char.isprintable() else " " for char in value[:limit])

    return clip


_SHAPE = {
    "uptime": finite_number,
    "kind": _text(64),
    "generated_at": _text(64),
    "hashrate": {"total": [plausible_rate]},
    "connection": {"uptime": finite_number, "pool": _text(255)},
    "rigforge": {
        "version": _text(64),
        "stamp": _text(256),
        "xmrig_api": _text(64),
        "tune": {"target": _text(64), "autotune": {"next": _text(64)}},
        "power": {"watts": finite_number, "hs_per_watt": finite_number},
        "health": {
            "governor": _text(64),
            "throttling": _flag,
            "hugepages_total": finite_number,
            "firmware": {"board": _text(128)},
        },
        "watchdog": {
            "mode": _text(64),
            "thermal_hold": _flag,
            "temp_c": finite_number,
            "max_temp_c": finite_number,
        },
        "control": {"change_id": _text(64), "status": _text(64), "reason": _clipped(500)},
        "config": {},
        "config_meta": {},
    },
}


def _shaped(value, shape):
    if isinstance(shape, dict):
        if not isinstance(value, dict):
            return None
        for key, rule in shape.items():
            if key in value:
                value[key] = _shaped(value[key], rule)
                if value[key] is None:
                    del value[key]
        return value
    if isinstance(shape, list):
        return [_shaped(item, shape[0]) for item in value] if isinstance(value, list) else None
    return shape(value)


def _bounded(value, depth=0):
    if depth > _DEPTH_MAX:
        return None
    if isinstance(value, dict):
        return {key[:_TEXT_MAX]: _bounded(item, depth + 1) for key, item in value.items()}
    if isinstance(value, list):
        return [_bounded(item, depth + 1) for item in value]
    if isinstance(value, str):
        return safe_text(value[:_TEXT_MAX], _TEXT_MAX)
    if isinstance(value, bool) or value is None:
        return value
    return value if -_NUMBER_MAX <= value <= _NUMBER_MAX else 0


def usable_reply(payload):
    return _bounded(_shaped(payload, _SHAPE))
