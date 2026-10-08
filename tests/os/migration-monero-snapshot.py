"""Validate the runner's isolated, consistent Monero snapshot and install only its database."""

import hashlib
import json
import os
import re
import stat
import sys


def read_regular(directory, name):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError("snapshot member is not a regular file")
    return fd


def digest(fd):
    result = hashlib.sha256()
    with os.fdopen(os.dup(fd), "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def validate(root):
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with os.fdopen(read_regular(directory, "snapshot.json"), "rb") as stream:
            raw = stream.read(8193)
        if len(raw) > 8192:
            raise ValueError("snapshot receipt exceeds its bound")
        receipt = json.loads(raw)
        if (
            not isinstance(receipt, dict)
            or type(receipt.get("schema")) is not int
            or receipt.get("schema") != 1
            or receipt.get("consistent") is not True
            or type(receipt.get("height")) is not int
            or receipt["height"] <= 0
            or not re.fullmatch(r"[0-9a-f]{64}", receipt.get("sha256", ""))
        ):
            raise ValueError("snapshot receipt is invalid")
        fd = read_regular(directory, "data.mdb")
        size = os.fstat(fd).st_size
        try:
            if digest(fd) != receipt["sha256"] or size <= 0:
                raise ValueError("snapshot database does not match its receipt")
        finally:
            os.close(fd)
        return size, receipt["height"], receipt["sha256"]
    finally:
        os.close(directory)


def install(source, destination, expected, *, data_root="/data"):
    # Every directory beneath the disposable guest's /data is pinned without following links.
    prefix = data_root.rstrip("/") + "/"
    pieces = destination.removeprefix(prefix).split("/")
    if not destination.startswith(prefix) or any(p in ("", ".", "..") for p in pieces):
        raise ValueError("snapshot destination is outside guest data")
    directory = os.open(data_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for piece in pieces + ["lmdb"]:
            try:
                os.mkdir(piece, 0o755, dir_fd=directory)
            except FileExistsError:
                pass
            child = os.open(piece, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        os.fchown(directory, 1000, 1000)
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            metadata = os.fstat(fd)
            if not stat.S_ISREG(metadata.st_mode) or digest(fd) != expected:
                raise ValueError("transferred database failed integrity verification")
            os.fchown(fd, 1000, 1000)
            os.fchmod(fd, 0o600)
            os.fsync(fd)
            current = os.stat(source, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino):
                raise ValueError("transferred database changed during installation")
            os.replace(source, "data.mdb", dst_dir_fd=directory)
        finally:
            os.close(fd)
        try:
            os.unlink("lock.mdb", dir_fd=directory)
        except FileNotFoundError:
            pass
        os.fsync(directory)
    finally:
        os.close(directory)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "validate":
            print(*validate(sys.argv[2]))
        elif sys.argv[1] == "install":
            install(*sys.argv[2:5])
        else:
            raise ValueError("unknown snapshot operation")
    except (OSError, ValueError, TypeError, KeyError):
        sys.exit("Monero snapshot validation or installation failed")
