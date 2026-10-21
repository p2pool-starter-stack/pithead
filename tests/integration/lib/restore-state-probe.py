# ruff: noqa: S603, S607, S608
import hashlib
import io
import json
import os
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

PASSPHRASE = b"reset recovery fixture"


def crypt(source, destination, decrypt=False):
    subprocess.run(
        [
            "openssl",
            "enc",
            *(["-d"] if decrypt else ["-salt"]),
            "-aes-256-cbc",
            "-pbkdf2",
            "-iter",
            "600000",
            "-pass",
            "stdin",
            "-in",
            str(source),
            "-out",
            str(destination),
        ],
        input=PASSPHRASE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
        timeout=60,
    )


def digest(stream):
    result = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        result.update(chunk)
    return result.hexdigest()


def file_digest(path):
    if path.is_symlink():
        raise ValueError("unexpected symbolic link")
    if not path.exists():
        return None
    with path.open("rb") as stream:
        return digest(stream)


def archive_paths(archive):
    root = Path.cwd()
    env = archive.extractfile(str(root / ".env").lstrip("/"))
    values = dict(line.split("=", 1) for line in env.read().decode().splitlines() if "=" in line)
    tor = Path(values["TOR_DATA_DIR"])
    db = Path(values["DASHBOARD_DATA_DIR"]) / "mining_data.db"
    if not tor.is_absolute() or not db.is_absolute():
        raise ValueError("archive data paths must be absolute")
    archive.getmember(str(db).lstrip("/"))
    if not any(
        member.isfile() and member.name.startswith(str(tor).lstrip("/") + "/") for member in archive
    ):
        raise ValueError("archive has no Tor files")
    return root, tor, db


def snapshot(archive):
    root, tor, db = archive_paths(archive)
    paths = [root / name for name in ("config.json", ".env", "Caddyfile")]
    if not tor.is_dir() or tor.is_symlink():
        raise ValueError("Tor directory missing or unsafe")
    paths.extend(sorted(tor.rglob("*")))
    paths.extend(Path(str(db) + suffix) for suffix in ("", "-wal", "-shm", "-journal"))
    if not db.is_file():
        raise ValueError("dashboard database missing")
    state = [
        (str(path), "directory" if path.is_dir() and not path.is_symlink() else file_digest(path))
        for path in paths
    ]
    return hashlib.sha256(json.dumps(state).encode()).hexdigest()


def database_counts(path):
    with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as connection:
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ValueError("dashboard database integrity check failed")
        if connection.execute("PRAGMA foreign_key_check").fetchall():
            raise ValueError("dashboard database foreign key check failed")
        tables = connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
        if not tables:
            raise ValueError("dashboard database has no tables")
        return {
            table: connection.execute(
                'SELECT count(*) FROM "' + table.replace('"', '""') + '"'
            ).fetchone()[0]
            for (table,) in tables
        }


def verify(archive, scratch):
    _, _, db = archive_paths(archive)
    archived_db = scratch / "dashboard.db"
    archived_db.write_bytes(archive.extractfile(str(db).lstrip("/")).read())
    for suffix in ("-wal", "-shm", "-journal"):
        name = str(db).lstrip("/") + suffix
        if name in archive.getnames():
            Path(str(archived_db) + suffix).write_bytes(archive.extractfile(name).read())
    restored_db = scratch / "restored.db"
    for suffix in ("", "-wal", "-shm", "-journal"):
        source = Path(str(db) + suffix)
        if source.exists():
            Path(str(restored_db) + suffix).write_bytes(source.read_bytes())
    if database_counts(archived_db) != database_counts(restored_db):
        raise ValueError("restored dashboard table counts differ from archive")
    for member in archive:
        if member.isfile() and file_digest(Path("/") / member.name) != digest(
            archive.extractfile(member)
        ):
            raise ValueError("restored file differs from archive")


def future_archive(archive, destination, scratch):
    config_name = str(Path.cwd() / "config.json").lstrip("/")
    version = Path("VERSION").read_text().strip().split("-")[0].split("+")[0]
    major, minor, patch = (int(part) for part in version.split("."))
    plain = scratch / "future.tar.gz"
    with tarfile.open(plain, "w:gz") as output:
        for member in archive:
            stream = archive.extractfile(member) if member.isfile() else None
            if member.name == config_name:
                config = json.load(stream)
                config["config_version"] = f"{major}.{minor}.{patch + 1}"
                data = json.dumps(config).encode()
                member.size = len(data)
                stream = io.BytesIO(data)
            output.addfile(member, stream)
    crypt(plain, destination)


def main():
    os.umask(0o077)
    action, source = sys.argv[1:3]
    with tempfile.TemporaryDirectory(prefix="restore-proof-") as directory:
        scratch = Path(directory)
        plain = scratch / "archive.tar.gz"
        crypt(source, plain, decrypt=True)
        with tarfile.open(plain, "r:gz") as archive:
            if action == "snapshot":
                print(snapshot(archive))
            elif action == "verify":
                verify(archive, scratch)
            elif action == "future":
                future_archive(archive, Path(sys.argv[3]), scratch)
            else:
                raise ValueError("unknown probe action")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("restore state probe failed", file=sys.stderr)
        sys.exit(1)
