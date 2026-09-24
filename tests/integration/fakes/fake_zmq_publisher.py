#!/usr/bin/env python3
"""One-shot ZMTP XPUB fixture for the integration probe self-test."""

import argparse
import socket
import time

GREETING = b"\xff" + b"\0" * 8 + b"\x7f\x03\x01NULL" + b"\0" * 48
READY = bytes.fromhex("041a0552454144590b536f636b65742d547970650000000458505542")
SUB_READY = bytes.fromhex("04190552454144590b536f636b65742d5479706500000003535542")


def read_exact(client, size):
    data = bytearray()
    while len(data) < size:
        if not (chunk := client.recv(size - len(data))):
            raise ConnectionError(f"short read: got {len(data)}, want {size}")
        data.extend(chunk)
    return bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--silent", action="store_true")
    args = parser.parse_args()

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(10)
        print(listener.getsockname()[1], flush=True)
        # The probe makes a bounded pre-connect before the real protocol connection.
        for _ in range(2):
            client, _ = listener.accept()
            with client:
                client.settimeout(10)
                greeting = client.recv(64)
                if not greeting:
                    continue
                greeting += read_exact(client, 64 - len(greeting))
                if greeting != GREETING:
                    raise ValueError("unexpected ZMTP greeting")
                client.sendall(GREETING)
                if read_exact(client, 27) != SUB_READY:
                    raise ValueError("expected ZMTP SUB READY")
                client.sendall(READY)
                if read_exact(client, 3) != b"\x00\x01\x01":
                    raise ValueError("expected empty-topic SUBSCRIBE")
                if args.silent:
                    time.sleep(2)
                else:
                    client.sendall(b"\x00\x01\x00")  # Short ZMTP data frame.
                return
        raise RuntimeError("probe never opened its protocol connection")


if __name__ == "__main__":
    main()
