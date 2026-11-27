"""Bounded reads of the active Caddy access log and its two shipped generations."""

import gzip
import io
import json
import os
import re
import stat
import zlib
from pathlib import Path

# Pinned Caddy's timberjack adds -size; older lumberjack backups omit it.
# Include plain files during compression, but never arbitrary sibling files.
_GENERATION = re.compile(
    r"access-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3})(?:-size)?\.log(?:\.gz)?"
)
FILE_BYTES = 4 * 1024 * 1024
GENERATIONS = 2


def _read(path: Path) -> list[dict] | None:
    """At most 4 MiB of JSON bytes, and 4 MiB compressed input for gzip files.

    Plain files use a tail; gzip uses a bounded decompressed prefix. Oversized
    files therefore yield partial history, never an unbounded decompression.
    Refuse links and special files even if a matching name appears in the mount.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            size = os.fstat(stream.fileno()).st_size
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                return None
            if path.suffix == ".gz":
                compressed = stream.read(FILE_BYTES)
                with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as decoded:
                    chunk = decoded.read(FILE_BYTES)
                cut = False
            else:
                stream.seek(max(0, size - FILE_BYTES))
                chunk = stream.read(FILE_BYTES)
                cut = size > FILE_BYTES
    except (OSError, EOFError, zlib.error):
        return None
    lines = chunk.split(b"\n")
    if cut:
        lines = lines[1:]
    # Caddy writes newline-terminated records; omit an unfinished final record.
    rows = []
    for line in lines[:-1]:
        try:
            row = json.loads(line)
        except (ValueError, UnicodeDecodeError, RecursionError):
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def access_rows(path: str) -> list[dict] | None:
    """Active log plus at most two newest unique backup timestamps, or None.

    Availability follows the active file. Missing/corrupt generations are ignored.
    Prefer plain if both names exist during compression: gzip may still be
    incomplete. A single request is never counted twice. Total JSON input is at most 12 MiB;
    compressed input adds at most 8 MiB. Directory selection retains two names.
    """
    active = Path(path)
    rows = _read(active)
    if rows is None:
        return None
    newest = {}
    try:
        with os.scandir(active.parent) as siblings:
            for sibling in siblings:
                match = _GENERATION.fullmatch(sibling.name)
                if match is None:
                    continue
                name = match[1]
                previous = newest.get(name)
                if previous is None or not sibling.name.endswith(".gz"):
                    newest[name] = sibling.name
                if len(newest) > GENERATIONS:
                    del newest[min(newest)]
    except OSError:
        return rows
    for name in sorted(newest):
        rows.extend(_read(active.parent / newest[name]) or [])
    return rows
