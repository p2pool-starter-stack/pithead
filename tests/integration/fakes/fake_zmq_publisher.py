#!/usr/bin/env python3
"""One-shot ZMTP XPUB fixture for the integration probe self-test."""

import argparse
import socket
import time

GREETING = b"\xff" + b"\0" * 8 + b"\x7f\x03\x01NULL" + b"\0" * 48
READY = bytes.fromhex("041a0552454144590b536f636b65742d547970650000000458505542")


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
                if not client.recv(64):
                    continue
                client.sendall(GREETING)
                client.recv(27)
                client.sendall(READY[:2])
                time.sleep(0.05)  # The probe reads the ZMTP header before its body.
                client.sendall(READY[2:])
                client.recv(3)  # Empty-topic SUBSCRIBE.
                if args.silent:
                    time.sleep(2)
                else:
                    client.sendall(b"\x00\x01\x00")  # Short ZMTP data frame.
                return
        raise RuntimeError("probe never opened its protocol connection")


if __name__ == "__main__":
    main()
