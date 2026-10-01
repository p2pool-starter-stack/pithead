"""Retain bounded Compose read streams without changing the membership snapshot."""

import argparse
import json
import os
import selectors
import signal
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

LIMIT = 65536


class Stream:
    """Keep complete lines only; clipping a secret before redaction can leak it."""

    def __init__(self, marker):
        self.marker = marker
        self.data = bytearray()
        self.pending = bytearray()
        self.dropping = False
        self.truncated = False
        self.compose_exit = None

    def feed(self, chunk, stderr=False):
        for part in chunk.splitlines(keepends=True):
            if not self.dropping:
                self.pending.extend(part)
                if len(self.pending) > LIMIT:
                    self.pending.clear()
                    self.dropping = True
                    self.truncated = True
            if part.endswith(b"\n"):
                if not self.dropping:
                    self.line(stderr)
                self.dropping = False

    def line(self, stderr=False):
        line = bytes(self.pending)
        self.pending.clear()
        if stderr and line.startswith(self.marker):
            value = line.strip().removeprefix(self.marker)
            if 1 <= len(value) <= 3 and value.isdigit() and int(value) <= 255:
                self.compose_exit = int(value)
                return
        if len(self.data) + len(line) <= LIMIT:
            self.data.extend(line)
        else:
            self.truncated = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("prefix")
    parser.add_argument("--status-marker", required=True)
    parser.add_argument("--seconds", type=float)
    parser.add_argument("--passthrough", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    streams = {name: Stream(args.status_marker.encode()) for name in ("stdout", "stderr")}
    metadata = {
        "captured_at": datetime.now(UTC).isoformat(),
        "byte_limit_per_stream": LIMIT,
        "time_limit_seconds": args.seconds,
    }
    proc = None
    try:
        # Trusted harness shell and configured transport, never artifact contents.
        proc = subprocess.Popen(  # noqa: S603
            args.command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True
        )
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ, "stdout")
            selector.register(proc.stderr, selectors.EVENT_READ, "stderr")
            deadline = time.monotonic() + args.seconds if args.seconds else None
            while selector.get_map():
                if deadline and time.monotonic() >= deadline:
                    metadata["capture_error"] = "time limit exceeded"
                    os.killpg(proc.pid, signal.SIGKILL)
                    break
                for key, _ in selector.select(0.1):
                    chunk = os.read(key.fileobj.fileno(), 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        streams[key.data].feed(chunk, key.data == "stderr")
                        if args.passthrough and key.data == "stdout":
                            sys.stdout.buffer.write(chunk)
                            sys.stdout.buffer.flush()
            try:
                remaining = max(0, deadline - time.monotonic()) if deadline else None
                metadata["transport_exit"] = proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                metadata["capture_error"] = "time limit exceeded"
    except OSError:
        metadata["capture_error"] = "could not start or read command"
    finally:
        if proc is not None:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            metadata["transport_exit"] = proc.wait()
            proc.stdout.close()
            proc.stderr.close()
    for name, stream in streams.items():
        if stream.pending:
            if metadata.get("capture_error"):
                stream.truncated = True
            else:
                stream.line(name == "stderr")
        metadata[f"{name}_truncated"] = stream.truncated
        (args.directory / f"{args.prefix}.{name}").write_bytes(stream.data)
    metadata["compose_exit"] = streams["stderr"].compose_exit
    if metadata["compose_exit"] is None:
        metadata.setdefault("capture_error", "Compose exit status unavailable")
    elif metadata["compose_exit"] != 0:
        metadata.setdefault("capture_error", "Compose read failed")
    (args.directory / f"{args.prefix}.json").write_text(json.dumps(metadata) + "\n")


if __name__ == "__main__":
    main()
