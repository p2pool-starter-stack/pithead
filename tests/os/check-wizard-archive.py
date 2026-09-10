#!/usr/bin/env python3
"""Verify the final wizard server in one Docker ``save`` archive."""

from __future__ import annotations

import json
import sys
import tarfile
from pathlib import Path, PurePosixPath

TARGET = PurePosixPath("app/mining_dashboard/wizard/server.py")
MAX_MANIFEST = 1 << 20
MAX_SOURCE = 4 << 20
MAX_OUTER_MEMBERS = 20_000
MAX_LAYER_MEMBERS = 1_000_000
MAX_LAYERS = 256
MAX_NAME = 4096


class InvalidArchive(Exception):
    pass


def clean_name(raw: str) -> PurePosixPath:
    if len(raw) > MAX_NAME:
        raise InvalidArchive("archive member path is oversized")
    name = raw.removeprefix("./")
    path = PurePosixPath(name)
    if not name or name.startswith("/") or "\\" in name or ".." in path.parts:
        raise InvalidArchive(f"unsafe archive member path: {raw!r}")
    return path


def read_small(member: tarfile.TarInfo, stream, limit: int) -> bytes:
    if not member.isfile() or member.size > limit:
        raise InvalidArchive(f"invalid or oversized member: {member.name}")
    data = stream.read(limit + 1)
    if len(data) != member.size or len(data) > limit:
        raise InvalidArchive(f"truncated or oversized member: {member.name}")
    return data


def docker_manifest(archive: Path) -> list[str]:
    manifests: list[bytes] = []
    seen: set[str] = set()
    count = 0
    try:
        with tarfile.open(archive, "r:gz") as outer:
            for member in outer:
                count += 1
                if count > MAX_OUTER_MEMBERS:
                    raise InvalidArchive("too many outer archive members")
                name = str(clean_name(member.name))
                if name in seen:
                    raise InvalidArchive(f"duplicate outer archive member: {name}")
                seen.add(name)
                if name == "manifest.json":
                    stream = outer.extractfile(member)
                    if stream is None:
                        raise InvalidArchive("manifest.json is not readable")
                    manifests.append(read_small(member, stream, MAX_MANIFEST))
    except (OSError, EOFError, tarfile.TarError) as exc:
        raise InvalidArchive(f"container archive is corrupt: {exc}") from exc
    if len(manifests) != 1:
        raise InvalidArchive("archive must contain exactly one manifest.json")
    try:
        manifest = json.loads(manifests[0])
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InvalidArchive("manifest.json is not valid JSON") from exc
    if not isinstance(manifest, list) or len(manifest) != 1 or not isinstance(manifest[0], dict):
        raise InvalidArchive("manifest.json must select exactly one image")
    layers = manifest[0].get("Layers")
    if not isinstance(layers, list) or not layers or len(layers) > MAX_LAYERS:
        raise InvalidArchive("manifest Layers must be a bounded non-empty list")
    if not all(isinstance(name, str) for name in layers):
        raise InvalidArchive("manifest layer names must be strings")
    cleaned = [str(clean_name(name)) for name in layers]
    if len(set(cleaned)) != len(cleaned):
        raise InvalidArchive("manifest contains duplicate layers")
    if not all(name.startswith("blobs/sha256/") or name.endswith("/layer.tar") for name in cleaned):
        raise InvalidArchive("manifest references an unsupported layer layout")
    return cleaned


def deletes_target(path: PurePosixPath) -> bool:
    name = path.name
    parent = path.parent
    if name == ".wh..wh..opq":
        return parent == TARGET.parent or parent in TARGET.parents
    if name.startswith(".wh."):
        victim = parent / name[4:]
        return victim == TARGET or victim in TARGET.parents
    return False


def layer_action(stream) -> tuple[str, bytes | None]:
    """Return the last target-affecting action in one layer."""
    action: tuple[str, bytes | None] = ("none", None)
    count = 0
    try:
        with tarfile.open(fileobj=stream, mode="r|*") as layer:
            for member in layer:
                count += 1
                if count > MAX_LAYER_MEMBERS:
                    raise InvalidArchive("too many layer archive members")
                path = clean_name(member.name)
                if deletes_target(path):
                    action = ("delete", None)
                    continue
                if path == TARGET:
                    if member.isfile():
                        source = layer.extractfile(member)
                        if source is None:
                            raise InvalidArchive("wizard server member is unreadable")
                        action = ("set", read_small(member, source, MAX_SOURCE))
                    elif member.isdir():
                        action = ("delete", None)
                    else:
                        raise InvalidArchive("wizard server may not be a link or special file")
                    continue
                if path in TARGET.parents and not member.isdir():
                    if member.issym() or member.islnk():
                        raise InvalidArchive("wizard server ancestor may not be a link")
                    action = ("delete", None)
    except (OSError, EOFError, tarfile.TarError) as exc:
        raise InvalidArchive(f"layer archive is corrupt: {exc}") from exc
    return action


def layer_actions(archive: Path, wanted: set[str]) -> dict[str, tuple[str, bytes | None]]:
    actions: dict[str, tuple[str, bytes | None]] = {}
    count = 0
    try:
        with tarfile.open(archive, "r:gz") as outer:
            for member in outer:
                count += 1
                if count > MAX_OUTER_MEMBERS:
                    raise InvalidArchive("too many outer archive members")
                name = str(clean_name(member.name))
                if name not in wanted:
                    continue
                if name in actions:
                    raise InvalidArchive(f"duplicate declared layer: {name}")
                if not member.isfile():
                    raise InvalidArchive(f"declared layer is not a regular file: {name}")
                stream = outer.extractfile(member)
                if stream is None:
                    raise InvalidArchive(f"declared layer is unreadable: {name}")
                actions[name] = layer_action(stream)
    except (OSError, EOFError, tarfile.TarError) as exc:
        raise InvalidArchive(f"container archive is corrupt: {exc}") from exc
    missing = wanted - actions.keys()
    if missing:
        raise InvalidArchive(f"manifest layer is missing: {sorted(missing)[0]}")
    return actions


def verify(archive: Path, expected: Path) -> None:
    try:
        source = expected.read_bytes()
    except OSError as exc:
        raise InvalidArchive(f"expected wizard source is unreadable: {exc}") from exc
    if len(source) > MAX_SOURCE:
        raise InvalidArchive("expected wizard source is oversized")
    layers = docker_manifest(archive)
    actions = layer_actions(archive, set(layers))
    final: bytes | None = None
    for name in layers:
        operation, content = actions[name]
        if operation == "set":
            final = content
        elif operation == "delete":
            final = None
    if final is None:
        raise InvalidArchive(f"final image has no {TARGET}")
    if final != source:
        raise InvalidArchive("shipped wizard/server.py differs from the tree")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: check-wizard-archive.py ARCHIVE EXPECTED", file=sys.stderr)
        return 2
    try:
        verify(Path(sys.argv[1]), Path(sys.argv[2]))
    except InvalidArchive as exc:
        print(f"     · {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
