"""Bounded, fail-closed archives of legacy and fingerprinted payout wallet caches."""

import hashlib
import re
import tarfile
from pathlib import PurePosixPath


def stream_digest(stream):
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(block)
    return value.hexdigest()


def archive_command(directory):
    # The private snapshot is validated before import; include every retained pair, not ringdb.
    return (
        f"cd {directory} && find . -maxdepth 1 -type f "
        "\\( -name 'payout-wallet*' -o -name '.payout-active' -o -name '.legacy-wallet-identity' \\) "
        "-printf '%f\\0' | tar --null -T - -cf -"
    )


def manifest(path):
    result = {}
    size = 0
    with tarfile.open(path, "r|") as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not member.isfile():
                raise ValueError("unsafe wallet archive member")
            name = str(name)
            # ponytail: cap fixture contents at 2 GiB; raise only for measured larger caches.
            size += member.size
            if size > 2 * 1024**3:
                raise ValueError("wallet fixture archive is too large")
            if name in result or member.uid != 1000 or member.gid != 1000 or member.mode != 0o600:
                raise ValueError("unexpected wallet archive ownership or mode")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("unreadable wallet archive member")
            result[name] = [member.mode, member.size, stream_digest(stream)]
    wallets = {name for name in result if re.fullmatch(r"payout-wallet(?:-[0-9a-f]{64})?", name)}
    allowed = {".payout-active", ".legacy-wallet-identity"}
    for name in wallets:
        allowed.update({name, name + ".keys", name + ".address.txt", name + ".unportable"})
    if (
        not wallets
        or set(result) - allowed
        or any(name + ".keys" not in result for name in wallets)
    ):
        raise ValueError("wallet archive must contain only complete prepared caches and keys")
    if not all(value[1] for value in result.values()):
        raise ValueError("wallet archive contains an empty member")
    return result
