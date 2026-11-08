import argparse
import importlib.util
import json
import struct
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("build_lmdb", ROOT / "scripts/tools/build-lmdb.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def run(*command):
    return subprocess.check_output([str(part) for part in command], text=True, timeout=30).strip()  # noqa: S603


def prove(archive, tools):
    for name in ("mdb_copy", "mdb_stat"):
        header = (tools / name).read_bytes()[:20]
        if header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\x3e\x00":
            raise ValueError(f"Not an x86_64 ELF binary: {name}")
        if "/lib64/ld-linux-x86-64.so.2" not in run("readelf", "-l", tools / name):
            raise ValueError(f"Unexpected ELF interpreter: {name}")
    subprocess.run(["/usr/bin/sha256sum", "-c", "SHA256SUMS"], cwd=tools, check=True, timeout=30)
    results = []
    with tempfile.TemporaryDirectory(prefix="pithead-lmdb-proof-") as temporary:
        work = Path(temporary)
        source = work / "liblmdb"
        builder.unpack(archive, source)
        fixture = work / "fixture"
        builder.compile_tool(source, fixture, ROOT / "tests/tools/lmdb-fixture.c")
        database = work / "database"
        database.mkdir()
        run(fixture, "seed", database)
        initial = int(run(fixture, "check", database))
        lock_format = struct.unpack_from("<I", (database / "lock.mdb").read_bytes(), 4)[0]
        if lock_format & 0xFFF != 2:
            raise AssertionError("Fixture does not use the supported version-2 live locks")
        writer = subprocess.Popen([str(fixture), "write", str(database)])  # noqa: S603
        try:
            deadline = time.monotonic() + 15
            while int(run(fixture, "check", database)) <= initial:
                if time.monotonic() >= deadline or writer.poll() is not None:
                    raise AssertionError("Writer did not advance")
                time.sleep(0.01)
            for number in range(12):
                if writer.poll() is not None:
                    raise AssertionError("Writer exited before copying finished")
                before = int(run(fixture, "check", database))
                copy = work / f"copy-{number}"
                copy.mkdir()
                mode = ["-c"] if number % 2 else []
                run(tools / "mdb_copy", *mode, database, copy)
                generation = int(run(fixture, "check", copy))
                after = int(run(fixture, "check", database))
                if not before <= generation <= after:
                    raise AssertionError("Copy generation is outside source transaction bounds")
                run(tools / "mdb_stat", "-ef", copy)
                run(tools / "mdb_stat", "-ef", database)
                results.append(
                    {
                        "mode": "compact" if mode else "ordinary",
                        "before": before,
                        "copy": generation,
                        "after": after,
                    }
                )
            final = int(run(fixture, "check", database))
            if final <= results[0]["before"] or writer.poll() is not None:
                raise AssertionError("Source did not advance while copies were made")
        finally:
            if writer.poll() is None:
                writer.terminate()
            if writer.wait(timeout=15) != 0:
                raise AssertionError("Writer did not finish cleanly")
        run(fixture, "check", database)
        run(fixture, "corrupt", copy)
        negative = subprocess.run([str(fixture), "check", str(copy)], check=False, timeout=30)  # noqa: S603
        if negative.returncode != 2:
            raise AssertionError("Independent verifier accepted inconsistent records")
        broken = work / "broken"
        broken.mkdir()
        (broken / "data.mdb").write_bytes(b"invalid LMDB database")
        for name in ("mdb_copy", "mdb_stat"):
            command = [str(tools / name), str(broken)]
            if name == "mdb_copy":
                destination = work / "bad-copy"
                destination.mkdir()
                command.append(str(destination))
            failed = subprocess.run(command, capture_output=True, check=False, timeout=30)  # noqa: S603
            if failed.returncode == 0:
                raise AssertionError(f"{name} accepted an invalid database")
    report = {
        "schema": 1,
        "lock_version": lock_format & 0xFFF,
        "copies": results,
        "source_initial": initial,
        "source_final": final,
        "inconsistent_records_rejected": True,
        "invalid_database_rejected": True,
        "source_readable_after_writer": True,
    }
    (tools / "proof.json").write_text(json.dumps(report, indent=2) + "\n")
    builder.write_checksums(tools)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("tools", type=Path)
    args = parser.parse_args()
    prove(args.archive.resolve(), args.tools.resolve())
