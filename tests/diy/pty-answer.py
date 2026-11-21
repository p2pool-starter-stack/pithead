import os
import pty
import re
import select
import sys
import time

PROMPT_END = re.compile(r"(: |\? |\) |\]: )$")


def answer_for(tail, wallet):
    if re.search(r"Monero Wallet Address", tail):
        return wallet
    if re.search(r"Merge-mine Tari", tail):
        return "1"
    if re.search(r"Start Pithead now", tail):
        return "n"
    return ""


def main():
    wallet, limit = sys.argv[1], int(sys.argv[2])
    command = sys.argv[3:]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(command[0], command)  # noqa: S606
    deadline = time.monotonic() + limit
    tail = ""
    quiet_since = time.monotonic()
    while True:
        if time.monotonic() > deadline:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
            print("pty-answer: timed out", file=sys.stderr)
            return 124
        ready, _, _ = select.select([fd], [], [], 0.5)
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            text = data.decode("utf-8", "replace")
            sys.stdout.write(text)
            sys.stdout.flush()
            tail = (tail + text)[-400:]
            quiet_since = time.monotonic()
        elif tail and PROMPT_END.search(tail.rstrip("\r")) and time.monotonic() - quiet_since > 1.0:
            os.write(fd, (answer_for(tail, wallet) + "\n").encode())
            tail = ""
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


sys.exit(main())
