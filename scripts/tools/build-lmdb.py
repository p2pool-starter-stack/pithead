import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

VERSION = "v0.18.5.1"
COMMIT = "4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5"
ARCHIVE_SHA256 = "4fdd15401af04e1ce84dcae40c8c114320d1cc9b449db25c0d57efa4b4054881"
SOURCE_URL = f"https://codeload.github.com/monero-project/monero/tar.gz/{COMMIT}"
FILES = ("mdb.c", "midl.c", "midl.h", "lmdb.h", "mdb_copy.c", "mdb_stat.c", "LICENSE", "COPYRIGHT")
FLAGS = ["-O2", "-pthread"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unpack(archive, destination):
    if digest(archive) != ARCHIVE_SHA256:
        raise ValueError("Monero source archive SHA-256 mismatch")
    prefix = f"monero-{COMMIT}/external/db_drivers/liblmdb/"
    destination.mkdir()
    with tarfile.open(archive) as source:
        for name in FILES:
            member = source.getmember(prefix + name)
            if not member.isfile() or member.size > 2_000_000:
                raise ValueError(f"Invalid source member: {name}")
            with source.extractfile(member) as stream:
                (destination / name).write_bytes(stream.read())


def compile_tool(source, output, main):
    flags = FLAGS
    command = [
        "/usr/bin/gcc",
        *flags,
        "-I",
        str(source),
        str(main),
        str(source / "mdb.c"),
        str(source / "midl.c"),
        "-o",
        str(output),
    ]
    subprocess.run(command, check=True, timeout=120)  # noqa: S603
    return [
        "gcc",
        *flags,
        "-I",
        "liblmdb",
        f"liblmdb/{Path(main).name}",
        "liblmdb/mdb.c",
        "liblmdb/midl.c",
        "-o",
        output.name,
    ]


def build(archive, output, pithead_commit):
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("The artifact requires Linux x86_64")
    if not re.fullmatch("[0-9a-f]{40}", pithead_commit):
        raise ValueError("A full Pithead source commit is required")
    root = Path(__file__).resolve().parents[2]
    if f"ARG MONERO_VERSION={VERSION}\n" not in (root / "build/monero/Dockerfile").read_text():
        raise ValueError("LMDB source pin differs from supported Monero")
    output.mkdir()
    with tempfile.TemporaryDirectory(prefix="pithead-lmdb-") as temporary:
        source = Path(temporary) / "liblmdb"
        unpack(archive, source)
        commands = []
        for name in ("mdb_copy", "mdb_stat"):
            commands.append(compile_tool(source, output / name, source / f"{name}.c"))
        for name in ("LICENSE", "COPYRIGHT"):
            shutil.copyfile(source / name, output / name)
        shutil.copytree(source, output / "liblmdb")
        toolchain = {"gcc": Path("/usr/bin/gcc"), "ld": Path("/usr/bin/ld")}
        for name, query in (
            ("cc1", "-print-prog-name=cc1"),
            ("libc", "-print-file-name=libc.so.6"),
        ):
            toolchain[name] = Path(
                subprocess.check_output(["/usr/bin/gcc", query], text=True).strip()  # noqa: S603
            )
        provenance = {
            "schema": 1,
            "monero_version": VERSION,
            "monero_commit": COMMIT,
            "source_url": SOURCE_URL,
            "source_archive_sha256": ARCHIVE_SHA256,
            "source_files_sha256": {name: digest(source / name) for name in FILES},
            "pithead_commit": pithead_commit,
            "target": "linux-x86_64",
            "linking": "dynamic glibc",
            "build_libc": subprocess.check_output(
                ["/usr/bin/getconf", "GNU_LIBC_VERSION"], text=True
            ).strip(),
            "commands": commands,
            "compiler": subprocess.check_output(
                ["/usr/bin/gcc", "--version"], text=True
            ).splitlines()[0],
            "linker": subprocess.check_output(["/usr/bin/ld", "--version"], text=True).splitlines()[
                0
            ],
            "build_os": platform.freedesktop_os_release(),
            "runner_image": {key: os.environ.get(key) for key in ("ImageOS", "ImageVersion")},
            "build_packages": subprocess.check_output(
                ["/usr/bin/dpkg-query", "-W", "gcc", "binutils", "libc6", "libc6-dev"], text=True
            ).splitlines(),
            "toolchain_sha256": {name: digest(file) for name, file in toolchain.items()},
            "binaries_sha256": {name: digest(output / name) for name in ("mdb_copy", "mdb_stat")},
        }
        (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    write_checksums(output)


def write_checksums(output):
    names = sorted(
        p.relative_to(output).as_posix()
        for p in output.rglob("*")
        if p.is_file() and p != output / "SHA256SUMS"
    )
    (output / "SHA256SUMS").write_text(
        "".join(f"{digest(output / name)}  {name}\n" for name in names)
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build standalone pinned Monero LMDB tools")
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("pithead_commit")
    args = parser.parse_args()
    build(args.archive.resolve(), args.output.resolve(), args.pithead_commit)
