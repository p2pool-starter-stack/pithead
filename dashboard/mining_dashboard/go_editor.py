import os
import sys

from mining_dashboard import go_channel
from mining_dashboard.go_wizard_config import _tree, _value

REFERENCE_FUNCTIONS = {}
PROVIDERS = {}
VERSION_PROVIDER = None
FUNCTIONS = (
    "leaf_paths",
    "approval_paths",
    "confirmed_paths",
    "missing_default_paths",
    "last_apply_state",
    "config_version_metadata",
    "editor_metadata",
)


def _shape(node):
    if isinstance(node, dict):
        return {key: _shape(value) for key, value in node.items()}
    if isinstance(node, list):
        return []
    return node if isinstance(node, bool) else None


def _call(operation, **arguments):
    result = go_channel.call(
        "wizard-config", {"operation": "editor-" + operation, "config": _tree(arguments, {})}
    )
    try:
        return _value(result, {})
    except (KeyError, TypeError, ValueError, RuntimeError) as error:
        raise RuntimeError("native editor metadata returned invalid data") from error


def _paths(value):
    if not isinstance(value, list) or any(not isinstance(path, str) for path in value):
        raise RuntimeError("native editor metadata returned invalid paths")
    return value


def _named():
    from mining_dashboard.service import config_operations

    return [
        path for paths in config_operations.APPROVAL_ENV_KEY_PATHS.values() for path in paths
    ] + list(config_operations.APPROVAL_ONLY_PATHS)


def leaf_paths(node, prefix=(), include_arrays=False):
    node.items()
    yield from _paths(
        _call("leaves", reference=_shape(node), prefix=list(prefix), include_arrays=include_arrays)
    )


def approval_paths(reference, cfg, free_paths, confirm_paths):
    del cfg
    return _paths(
        _call(
            "approval",
            reference=_shape(reference),
            free_paths=list(free_paths),
            confirm_paths=list(confirm_paths),
            approval_named=_named(),
        )
    )


def confirmed_paths(reference, free_paths, confirm_paths, approval_paths):
    return _paths(
        _call(
            "confirmed",
            reference=_shape(reference),
            free_paths=list(free_paths),
            confirm_paths=list(confirm_paths),
            approval_paths=list(approval_paths),
        )
    )


def _with_getter(reference, host, getter):
    from mining_dashboard.service import config_operations

    return config_operations._defaults_with_getter(reference, host, getter)


def missing_default_paths(reference, host, getter):
    if getter is not PROVIDERS.get("getter"):
        return _with_getter(reference, host, getter)
    return _paths(_call("defaults", reference=_shape(reference), host=_shape(host)))


def _audit_snapshot(entries):
    return [
        {key: entry[key] for key in ("action", "status", "id") if key in entry}
        if isinstance(entry, dict)
        else entry
        for entry in entries
    ]


def _entries(entries):
    return [
        {
            key: value if isinstance(value := entry.get(key), str) else None
            for key in ("action", "status")
        }
        if isinstance(entry, dict)
        else (type(entry)() if type(entry) in (str, bool, int, float) else _shape(entry))
        for entry in entries
    ]


def _last_apply(index, entries):
    if index is None:
        return None
    if (
        type(index) is not int
        or not 0 <= index < len(entries)
        or not isinstance(entries[index], dict)
    ):
        raise RuntimeError("native editor metadata returned invalid audit index")
    entry = entries[index]
    if entry.get("action") not in ("commit", "commit-confirmed", "commit-approved") or entry.get(
        "status"
    ) not in ("applied", "failed"):
        raise RuntimeError("native editor metadata returned invalid audit state")
    return {"status": entry["status"], "id": entry.get("id", "")}


def last_apply_state(entries):
    entries = _audit_snapshot(entries)
    return _last_apply(_call("last-apply", entries=_entries(entries)), entries)


def _with_version_provider(cfg, host):
    from mining_dashboard.service import config_operations

    return config_operations._version_with_provider(cfg, host)


def _version_arguments(host):
    stamp = host.get("config_version")
    return {
        "stamp": stamp if isinstance(stamp, str) else None,
        "stamp_missing": stamp is None,
        "current": os.environ.get("PITHEAD_VERSION", ""),
        "max_digits": sys.get_int_max_str_digits(),
    }


def _version_flags(reply):
    if not isinstance(reply, dict) or any(
        type(reply.get(key)) is not bool for key in ("pop_version", "newer")
    ):
        raise RuntimeError("native editor metadata returned invalid version flags")


def _apply_version(cfg, reply):
    if reply["pop_version"]:
        cfg.pop("config_version", None)
    cfg["_config_version_newer"] = reply["newer"]
    return cfg


def config_version_metadata(cfg, host):
    from mining_dashboard.service import config_operations

    if config_operations.parse_semver is not VERSION_PROVIDER:
        return _with_version_provider(cfg, host)
    arguments = _version_arguments(host)
    try:
        reply = _call("version", **arguments)
    except ValueError:
        if arguments["stamp_missing"]:
            cfg.pop("config_version", None)
        raise
    if not isinstance(reply, dict) or set(reply) != {"pop_version", "newer"}:
        raise RuntimeError("native editor metadata returned invalid version result")
    _version_flags(reply)
    return _apply_version(cfg, reply)


def _with_providers(
    cfg,
    host,
    reference,
    *,
    core_loader,
    editable_provider,
    confirm_provider,
    getter,
    audit_provider,
):
    from mining_dashboard.service import config_operations

    return config_operations._editor_with_providers(
        cfg,
        host,
        reference,
        core_loader=core_loader,
        editable_provider=editable_provider,
        confirm_provider=confirm_provider,
        getter=getter,
        audit_provider=audit_provider,
    )


def editor_metadata(
    cfg,
    host,
    reference,
    *,
    core_loader,
    editable_provider,
    confirm_provider,
    getter,
    audit_provider,
):
    from mining_dashboard.service import config_operations

    providers = {
        "core_loader": core_loader,
        "editable_provider": editable_provider,
        "confirm_provider": confirm_provider,
        "getter": getter,
        "audit_provider": audit_provider,
    }
    if (
        any(provider is not PROVIDERS.get(name) for name, provider in providers.items())
        or config_operations.parse_semver is not VERSION_PROVIDER
        or any(getattr(config_operations, name) is not globals()[name] for name in FUNCTIONS[:-1])
    ):
        return _with_providers(cfg, host, reference, **providers)
    staged = dict(cfg)
    staged["_core_keys"] = core_loader()
    staged["_editable_keys"] = editable_provider()
    explicit = confirm_provider(staged)
    approval_free = editable_provider()
    confirmed_free = editable_provider()
    entries = _audit_snapshot(audit_provider())
    reply = _call(
        "metadata",
        reference=_shape(reference),
        host=_shape(host),
        explicit_confirm=explicit,
        approval_free=approval_free,
        confirmed_free=confirmed_free,
        approval_named=_named(),
        entries=_entries(entries),
        **_version_arguments(host),
    )
    if not isinstance(reply, dict) or set(reply) != {
        "confirm_keys",
        "approval_keys",
        "default_keys",
        "last_apply_index",
        "pop_version",
        "newer",
    }:
        raise RuntimeError("native editor metadata returned invalid plan")
    for key in ("confirm_keys", "approval_keys", "default_keys"):
        _paths(reply[key])
    _version_flags(reply)
    last = _last_apply(reply["last_apply_index"], entries)
    cfg["_core_keys"] = staged["_core_keys"]
    cfg["_editable_keys"] = staged["_editable_keys"]
    cfg["_confirm_keys"] = reply["confirm_keys"]
    cfg["_approval_keys"] = reply["approval_keys"]
    cfg["_default_keys"] = reply["default_keys"]
    cfg["_last_apply"] = last
    return _apply_version(cfg, reply)


def install():
    global VERSION_PROVIDER
    from mining_dashboard.service import audit_service, config_operations, control_service

    if not PROVIDERS:
        PROVIDERS.update(
            core_loader=control_service._load_core_keys,
            editable_provider=control_service._editable_paths,
            confirm_provider=control_service._confirm_paths,
            getter=control_service._get,
            audit_provider=audit_service.recent_changes,
        )
    if VERSION_PROVIDER is None:
        VERSION_PROVIDER = config_operations.parse_semver
    for name in FUNCTIONS:
        REFERENCE_FUNCTIONS.setdefault(name, getattr(config_operations, name))
        setattr(config_operations, name, globals()[name])
