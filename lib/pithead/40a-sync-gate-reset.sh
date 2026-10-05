# shellcheck shell=bash
# Atomic sync-gate marker shared by apply and its privileged retry.
rearm_sync_gate_marker() { # <dashboard-dir> <scope>
    python3 - "$1" "${2:-1}" <<'PYMARKER'
import os
import secrets
import stat
import sys

# Pin the directory and retain every descriptor. Its owner can replace entries,
# but cannot redirect a privileged open/write or block a read through a FIFO.
directory = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
temporary = ".sync-gate-reset." + secrets.token_hex(16)
try:
    tari_only = sys.argv[2] == "2"
    if tari_only:
        try:
            previous = os.open("sync-gate-reset", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            # A dangling link is an existing invalid/full marker, not absence.
            try:
                os.stat("sync-gate-reset", dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                tari_only = False
        except OSError:
            tari_only = False
        else:
            try:
                tari_only = stat.S_ISREG(os.fstat(previous).st_mode) and os.read(previous, 32) == b"tari-only\n"
            finally:
                os.close(previous)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    try:
        # Scope contains no secrets; the dashboard must read a sudo-created marker.
        os.fchmod(descriptor, 0o644)
        if tari_only:
            os.write(descriptor, b"tari-only\n")
        owned = os.fstat(descriptor)
        os.replace(temporary, "sync-gate-reset", src_dir_fd=directory, dst_dir_fd=directory)
        published = os.stat("sync-gate-reset", dir_fd=directory, follow_symlinks=False)
        if (published.st_dev, published.st_ino) != (owned.st_dev, owned.st_ino):
            raise OSError("sync-gate marker replaced during publication")
    finally:
        os.close(descriptor)
finally:
    try:
        os.unlink(temporary, dir_fd=directory)
    except FileNotFoundError:
        pass
    os.close(directory)
PYMARKER
}
