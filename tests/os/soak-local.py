#!/usr/bin/env python3
"""Portable workstation operations for the soak probe; never runs on the guest."""

import base64
import binascii
import hashlib
import subprocess
import sys
from datetime import datetime, timezone

# Stock macOS Python can precede 3.11, which introduced datetime.UTC.
UTC = timezone.utc  # noqa: UP017


def main():
    operation, *args = sys.argv[1:]
    if operation == "epoch":
        # Accept only the UTC format written by the probe, not locale-dependent dates.
        value = datetime.strptime(args[0], "%Y-%m-%dT%H:%M:%SZ")
        if value.strftime("%Y-%m-%dT%H:%M:%SZ") != args[0]:
            raise ValueError("invalid UTC timestamp")
        print(int(value.replace(tzinfo=UTC).timestamp()))
    elif operation == "utc":
        print(datetime.fromtimestamp(int(args[0]), UTC).strftime("%Y-%m-%dT%H:%M:%SZ"))
    elif operation == "sha256":
        print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
    elif operation == "decode":
        sys.stdout.buffer.write(
            base64.b64decode(b"".join(sys.stdin.buffer.read().split()), validate=True)
        )
    elif operation == "timeout":
        try:
            # The caller supplies fixed SSH argv; readings are never commands or shell text.
            result = subprocess.run(args[1:], timeout=float(args[0]), check=False)  # noqa: S603
            return result.returncode if result.returncode >= 0 else 128 - result.returncode
        except subprocess.TimeoutExpired:
            return 124
        except FileNotFoundError:
            return 127
        except PermissionError:
            return 126
    else:
        raise ValueError("unknown operation")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, IndexError, OSError, binascii.Error):
        # No input, SSH arguments or private readings in diagnostics.
        print("soak local operation failed", file=sys.stderr)
        sys.exit(1)
