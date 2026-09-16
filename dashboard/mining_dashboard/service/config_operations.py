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


# Env-var -> config-path map for the APPROVAL-gated tier (2026-09-13 perimeter audit), mirroring pithead's
# CONTROL_DASHBOARD_APPROVAL_KEYS exactly as control_service's two maps mirror their allowlists
# (drift-guarded in tests/service/test_env_key_perimeter.py). This is the NARROWEST tier and the
# one to be most suspicious of: #2076 removed the second identity it rested on, so its envelope is
# a typed confirmation the dashboard container can write itself. pithead's own list carries the
# full argument for what may join it -- read that before adding anything here.
APPROVAL_ENV_KEY_PATHS = {
    "TELEGRAM_ENABLED": ("telegram.enabled",),
    "TELEGRAM_COMMANDS_ENABLED": ("telegram.commands.enabled",),
}
# dashboard.energy is config.json-only (#504), so the price feed carries no env key to map; the
# host gate names it by path for the same reason.
APPROVAL_ONLY_PATHS = ("dashboard.energy.price_feed",)


def approval_paths(reference, cfg, free_paths, confirm_paths):
    """Return the NAMED approval-tier leaves that exist in the schema and are not already free.

    The tier used to be "every schema leaf that is not free, not confirm and not
    physical-presence" (#1978), so that every reference leaf had some route. Once #2076 removed the
    second identity that tier rested on, that rule meant the dashboard offered the whole security
    perimeter -- wallets, view keys, node and stratum credentials, the Tor egress firewall, onion
    exposure, the control channel's own switch -- behind an envelope the container writes itself.
    The tier is a short named list now (2026-09-13 perimeter audit); a leaf in none of the three tiers is host-only and
    renders disabled, which is what SECURITY.md and docs/appliance.md promise operators.
    """
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
