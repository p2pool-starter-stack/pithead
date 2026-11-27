"""Run the real setup rerun, answering prompts only when they appear."""

import argparse
import errno
import os
import pty
import re
import select
import signal
import sys
import time


def terminate(signum, _frame):
    sys.exit(128 + signum)


def setup_output(timeout):
    pid, terminal = pty.fork()
    if pid == 0:
        os.environ["NO_COLOR"] = "1"
        # Fixed argv invokes the checkout's candidate CLI, never a supplied command.
        os.execv("./pithead", ["./pithead", "setup", "--skip-deps", "--skip-optimize"])  # noqa: S606
    signal.signal(signal.SIGTERM, terminate)
    output = bytearray()
    prompts = [
        (rb"(?m)^Re-run setup \(re-provisions Tor and may modify GRUB\)\? \(y/N\): ", b"y\n"),
        (rb"(?m)^Enter Hostname \[[^\r\n]*\]: ", b"\n"),
        (rb"(?m)^Start Pithead now\? \(Y/n\): ", b"n\n"),
    ]
    deadline = time.monotonic() + timeout
    completed = False
    try:
        while time.monotonic() < deadline:
            if not select.select([terminal], [], [], 0.1)[0]:
                continue
            try:
                chunk = os.read(terminal, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                chunk = b""
            if not chunk:
                _, status = os.waitpid(pid, 0)
                completed = True
                return bytes(output), os.waitstatus_to_exitcode(status)
            output.extend(chunk)
            # A bounded capture stays in memory on the target; it is never a log file.
            if len(output) > 2 * 1024 * 1024:
                return bytes(output), 75
            for pattern, answer in prompts[:]:
                if re.search(pattern, output):
                    os.write(terminal, answer)
                    prompts.remove((pattern, answer))
        return bytes(output), 124
    finally:
        if not completed:
            # Own only this PTY child's process group, and reap it before returning.
            try:
                os.killpg(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            until = time.monotonic() + 5
            while time.monotonic() < until:
                if os.waitpid(pid, os.WNOHANG)[0]:
                    break
                time.sleep(0.1)
            else:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
        os.close(terminal)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    output, rc = setup_output(args.timeout)
    sys.stdout.buffer.write(output)
    return rc if rc >= 0 else 128 - rc


if __name__ == "__main__":
    sys.exit(main())
