import json
import os

from mining_dashboard import go_channel
from mining_dashboard.go_wizard_config import _check_strip_shapes, _tree, _value

REFERENCE_FUNCTIONS = {}


def _call(operation, *, plain=None, **values):
    identities = {}
    payload = {key: _tree(value, identities) for key, value in values.items()}
    payload.update(plain or {})
    result = go_channel.call("wizard-values", {"operation": operation, **payload})
    return result, {number: value for number, value in identities.values()}


def tari_disk_default(budget, disks, target, wipe="keep"):
    from mining_dashboard.wizard import defaults

    if not disks:
        budget.get("tari_chain_held")
    result, identities = _call(
        "tari", budget={} if disks else budget, disks=disks, target=target, wipe=wipe
    )
    if result.get("need_default"):
        return defaults.default_of("tari.mode")
    return _value(result["value"], identities)


def new_machine_answers(budget, disks, platform="appliance"):
    from mining_dashboard.wizard import defaults

    base = defaults.new_install_defaults(platform)
    mode = defaults.tari_disk_default(budget, disks, "")
    result, identities = _call("answers", base=base, mode=mode)
    return _value(result, identities)


def _apply_paths(written, cfg, paths):
    for path in paths:
        source, parent = cfg, written
        for key in path[:-1]:
            source = source[key]
            parent = parent.setdefault(key, {})
        parent[path[-1]] = source[path[-1]]


def explicit_wizard_config(cfg, ref):
    from mining_dashboard.config.defaults import TABLE

    if ref:
        _check_strip_shapes(cfg, ref)
    if not isinstance(cfg, dict):
        cfg.get("")
    paths = TABLE["materialize"] + ["monero.clearnet_initial_sync", "tari.clearnet_initial_sync"]
    result, identities = _call("explicit", config=cfg, reference=ref, plain={"paths": paths})
    written = cfg if result["same"] else _value(result["value"], identities)
    _apply_paths(written, cfg, result["aliases"])
    _apply_paths(written, cfg, result["paths"])
    return written


def _capacity(text):
    result = {"digit": text.isdigit()}
    if result["digit"]:
        try:
            result["integer"] = str(int(text))
        except ValueError as error:
            result["error"] = str(error)
    return result


def disk_inventory(raw):
    rows = []
    for line in raw.splitlines():
        parts = line.split("\t")
        rows.append(
            {
                "parts": [_tree(part, {}) for part in parts],
                "capacities": [_capacity(part) for part in parts[5:7]],
            }
        )
    result, identities = _call("inventory", plain={"rows": rows})
    return _value(result, identities)


def _remove(spool, names):
    return go_channel.call(
        "wizard-values", {"operation": "remove-spool", "spool": spool, "names": names}
    )


def remove_spool(spool, *names):
    for name in names:
        os.path.join(spool, name)
        _remove(os.fspath(spool), [os.fspath(name)])


def remember_changes(spool, changes, read_json, write_text):
    previous = read_json("config-changes.json").get("changes", [])
    result, identities = _call("remember", previous=previous, changes=list(changes))
    combined = _value(result, identities)
    if combined:
        write_text("config-changes.json", json.dumps({"changes": combined}))
    else:
        remove_spool(spool, "config-changes.json")


def install(server):
    from mining_dashboard import wizard_recovery
    from mining_dashboard.wizard import defaults

    for name in (
        "tari_disk_default",
        "new_machine_answers",
        "explicit_wizard_config",
        "disk_inventory",
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(defaults, name))
        setattr(defaults, name, globals()[name])
        setattr(server, name, globals()[name])
    for name in ("remember_changes", "remove_spool"):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(wizard_recovery, name))
        setattr(wizard_recovery, name, globals()[name])
        if hasattr(server, name):
            setattr(server, name, globals()[name])
