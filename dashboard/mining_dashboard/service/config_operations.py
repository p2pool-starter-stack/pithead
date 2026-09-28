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


# Env-var -> config-path map for the legacy approval-envelope tier, mirrored from pithead and
# drift-guarded in tests/service/test_env_key_perimeter.py. The envelope is confirmation metadata
# the dashboard can write itself, not a second identity.
APPROVAL_ENV_KEY_PATHS = {
    "TELEGRAM_ENABLED": ("telegram.enabled",),
    "TELEGRAM_COMMANDS_ENABLED": ("telegram.commands.enabled",),
    "HOST_IP": ("dashboard.host",),
}
# dashboard.energy is config.json-only (#504), so the price feed carries no env key to map; the
# host gate names it by path for the same reason.
APPROVAL_ONLY_PATHS = ("dashboard.energy.price_feed",)


def approval_paths(reference, cfg, free_paths, confirm_paths):
    """Return named approval-envelope leaves that exist and are not already classified."""
    free = set(free_paths)
    confirm = set(confirm_paths)
    named = {p for t in APPROVAL_ENV_KEY_PATHS.values() for p in t}.union(APPROVAL_ONLY_PATHS)
    return sorted(
        path
        for path in leaf_paths(reference)
        if path in named
        and path not in free
        and path not in confirm
        and path not in NEVER_APPROVE_PATHS
        and not path.startswith("ssh.")
    )


def confirmed_paths(reference, free_paths, confirm_paths, approval_paths):
    """Route every remaining schema leaf through typed confirmation (#1959)."""
    classified = set(free_paths) | set(confirm_paths) | set(approval_paths)
    return sorted(
        path
        for path in leaf_paths(reference)
        if path not in classified
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
