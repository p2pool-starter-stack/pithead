"""Resolve the running stack's version for the dashboard header badge (Issue #58).

The values are baked into the image at build time as environment variables (see the
dashboard ``Dockerfile`` build-args, fed by ``pithead`` from the top-level ``VERSION`` file
— the single source of truth — and ``git``). Reading only the environment keeps the
container self-describing and this resolver a pure, unit-testable function of its inputs.
"""

import os


def _flag(value):
    """Truthy interpretation of an env flag string."""
    return (value or "").strip().lower() in ("1", "true", "yes", "on")


def resolve_version(env=None):
    """Return ``{"text", "title", "dev"}`` describing the running build.

    - Released build   -> ``{"text": "v1.3.0", "dev": False}``
    - Dev/working tree -> ``{"text": "dev@<short hash>", "dev": True}``

    ``text`` is the badge label, ``title`` its hover tooltip, and ``dev`` lets the client
    tell a release from a working-tree build. Source of truth is the top-level ``VERSION``
    file, surfaced as ``PITHEAD_VERSION``. A build counts as a release when
    ``PITHEAD_RELEASE`` is set, or when a version is present with no git metadata (a release
    tarball built without a working tree); otherwise it's a dev build.
    """
    env = os.environ if env is None else env
    version = (env.get("PITHEAD_VERSION") or "").strip()
    if version.startswith("v"):
        version = version[1:]
    short_commit = (env.get("PITHEAD_GIT_COMMIT") or "").strip()
    branch = (env.get("PITHEAD_GIT_BRANCH") or "").strip()
    full_commit = (env.get("PITHEAD_GIT_COMMIT_FULL") or "").strip()
    build_time = (env.get("PITHEAD_BUILD_TIME") or "").strip()
    build_kind = (env.get("PITHEAD_BUILD_KIND") or "").strip()
    build_slot = (env.get("PITHEAD_BUILD_SLOT") or "").strip()

    is_release = _flag(env.get("PITHEAD_RELEASE")) or (bool(version) and not short_commit)
    if is_release and version:
        return {"text": f"v{version}", "title": f"Pithead release v{version}", "dev": False}

    text = f"dev@{short_commit}" if short_commit else "dev build"
    footer = {}
    if full_commit:
        footer["footer_commit"] = full_commit
    if build_time:
        footer["footer_build_time"] = build_time
    if build_kind:
        footer["footer_kind"] = build_kind
    if build_slot:
        footer["footer_slot"] = build_slot

    detail = branch or short_commit
    return {"text": text, "title": f"Dev build ({detail})" if detail else "Dev build", "dev": True, **footer}
