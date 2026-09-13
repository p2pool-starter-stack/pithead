"""Pure classification helpers for the day-two configuration surface."""

NEVER_APPROVE_PATHS = frozenset(
    {
        "dashboard.auth.password",
        "telegram.events.wallet_changed",
        "telegram.events.clearnet_exposed",
    }
)

EDITOR_METADATA = frozenset(
    {
        "_core_keys",
        "_editable_keys",
        "_confirm_keys",
        "_approval_keys",
        "_default_keys",
        "_last_apply",
    }
)


def _is_secret_sentinel(value):
    return isinstance(value, dict) and value.get("__secret__") is True


def leaf_paths(node, prefix=()):
    """Yield scalar schema paths; arrays use their dedicated/JSON surfaces."""
    for key, value in node.items():
        if key.startswith("_"):
            continue
        path = (*prefix, key)
        if isinstance(value, dict) and not _is_secret_sentinel(value):
            yield from leaf_paths(value, path)
        elif not isinstance(value, list):
            yield ".".join(path)


def approval_paths(reference, cfg, free_paths, confirm_paths):
    """Classify every non-free schema leaf outside the physical-presence set as approval."""
    free = set(free_paths)
    confirm = set(confirm_paths)
    return sorted(
        path
        for path in leaf_paths(reference)
        if path not in free
        and path not in confirm
        and path not in NEVER_APPROVE_PATHS
        and not path.startswith("ssh.")
    )


def missing_default_paths(reference, host, getter):
    """Return schema leaves omitted by the sparse host config."""
    return [
        dotted for dotted in leaf_paths(reference) if not getter(host, tuple(dotted.split(".")))[0]
    ]


def last_apply_state(entries):
    """Return the newest terminal dashboard apply, not a desired-state guess."""
    for entry in entries:
        if entry.get("action") in ("commit", "commit-confirmed", "commit-approved") and entry.get(
            "status"
        ) in ("applied", "failed"):
            return {"status": entry["status"], "id": entry.get("id", "")}
    return None


def strip_editor_metadata(cfg):
    """Remove response-only fields before a candidate reaches the host schema gate."""
    return {key: value for key, value in cfg.items() if key not in EDITOR_METADATA}
