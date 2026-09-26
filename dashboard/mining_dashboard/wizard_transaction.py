"""One wizard submission as a transaction over the spool, and the cleanup that keeps it one.

A submission publishes ``submission-staging`` first and ``submission-active`` last; the host
ignores a generation until the final marker exists. This module names the files one submission
owns, refuses a second submission while one is in flight, and rolls a failed one back —
including the restore passphrase in the volatile restore dir and any hidden temporary an
interrupted atomic write left behind. ``make_app`` runs the temporary sweep at startup too.
"""

import os
import stat
import tempfile

from aiohttp import web

# The files one submission owns while the host has not finished with it: any of them present
# means a submission is still in flight.
TRANSACTION_FILES = (
    "restore-archive",
    "restore-inflight",
    "install-attempt.json",
    "install-request",
    "submission-staging",
    "submission-active",
    "config.json",
    "rig-request.json",
)
# Written beside a request, never alone: a new submission clears them before staging its own.
SUBMISSION_SIDECARS = ("auth-mode", "role")
ROLLBACK_FILES = (*TRANSACTION_FILES, *SUBMISSION_SIDECARS, "last-attempt.json")
# Every name the page publishes through a hidden ".<name>." temporary (see spool_write).
PAGE_TEMP_FILES = (*ROLLBACK_FILES, "restore-passphrase")


def spool_dir() -> str:
    """The persistent spool the host reads submissions from."""
    return os.environ.get("WIZARD_SPOOL", "/wizard-spool")


def restore_dir() -> str:
    """The volatile restore dir: host-side root-owned tmpfs, never the persistent spool."""
    return os.environ.get("WIZARD_RESTORE", "/wizard-restore")


def spool_remove(name: str, directory: str | None = None) -> None:
    try:
        os.unlink(os.path.join(directory or spool_dir(), name))
    except FileNotFoundError:
        pass


def spool_exists(name: str) -> bool:
    return os.path.lexists(os.path.join(spool_dir(), name))


def spool_write(name: str, data: str | bytes, directory: str | None = None) -> None:
    """Atomic like the config write: the host's loop must never see a partial file. A failed
    write removes its own temporary, so no half-written secret is left under a hidden name."""
    sd = directory or spool_dir()
    os.makedirs(sd, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=sd, prefix=f".{name}.")
    try:
        with os.fdopen(fd, "wb" if isinstance(data, bytes) else "w") as f:
            f.write(data)
        os.replace(tmp, os.path.join(sd, name))
    except OSError:
        try:
            os.close(fd)
        except OSError:
            pass
        spool_remove(os.path.basename(tmp), sd)
        raise


def submission_conflict() -> web.Response | None:
    """Refuse a second submission while one is in flight (409). A passphrase left behind with no
    archive is an interrupted restore: clear it, or answer 500 when that cannot be done safely."""
    if any(
        spool_exists(name) for name in ("restore-archive", "restore-inflight")
    ) or os.path.lexists(os.path.join(restore_dir(), "restore-archive")):
        return web.json_response(
            {"error": "another setup submission is already being processed"}, status=409
        )
    passphrase = os.path.lexists(os.path.join(restore_dir(), "restore-passphrase"))
    if passphrase and not clear_failed_restore():
        return web.json_response(
            {"error": "an incomplete restore submission could not be cleared safely"}, status=500
        )
    if any(spool_exists(name) for name in (*TRANSACTION_FILES, "installing")):
        return web.json_response(
            {"error": "another setup submission is already being processed"}, status=409
        )
    return None


def clear_submission_sidecars() -> None:
    """Drop the previous submission's sidecars before this one stages its own."""
    for name in SUBMISSION_SIDECARS:
        spool_remove(name)


def clear_failed_restore() -> bool:
    """Roll a failed submission back: the passphrase and any archive in the restore dir, every
    file the submission owns in the spool, and the temporaries. False when any could not go."""
    ok = True
    targets = [(name, restore_dir()) for name in ("restore-passphrase", "restore-archive")]
    targets.extend((name, None) for name in ROLLBACK_FILES)
    for name, directory in targets:
        try:
            spool_remove(name, directory)
        except OSError:
            ok = False
    return clear_page_temps() and ok


def clear_page_temps() -> bool:
    """Remove the hidden temporaries an interrupted spool_write left in either dir. Anything under
    such a name that is not a file or link is left alone and reported as a failure."""
    ok = True
    for directory in (spool_dir(), restore_dir()):
        try:
            entries = os.listdir(directory)
        except FileNotFoundError:
            continue
        except OSError:
            ok = False
            continue
        for entry in entries:
            if any(entry.startswith(f".{name}.") for name in PAGE_TEMP_FILES):
                try:
                    mode = os.lstat(os.path.join(directory, entry)).st_mode
                    if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
                        ok = False
                        continue
                    spool_remove(entry, directory)
                except FileNotFoundError:
                    pass
                except OSError:
                    ok = False
    return ok
