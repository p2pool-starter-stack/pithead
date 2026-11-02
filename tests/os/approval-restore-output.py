import re
import sys
from collections import deque

PHRASES = (
    "permission denied",
    "operation not permitted",
    "no such file or directory",
    "no space left on device",
    "read-only file system",
    "input/output error",
    "connection refused",
    "connection reset",
    "connection closed",
    "connection timed out",
    "host key verification failed",
    "could not resolve hostname",
    "command not found",
    "not a directory",
    "is a directory",
    "invalid argument",
    "unknown option",
    "unrecognized option",
    "syntax error",
    "unexpected end of file",
    "failed to apply",
    "configuration invalid",
    "configuration validation failed",
    "control spool still holds",
    "in-flight request(s) after the drain deadline",
)
PATTERN = re.compile("|".join(re.escape(phrase) for phrase in PHRASES), re.I)
CONTROL = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|[\x00-\x1f\x7f]")


def main():
    diagnostics = deque(maxlen=12)
    total = 0
    redacted = False
    for chunk in iter(lambda: sys.stdin.buffer.readline(4096), b""):
        text = CONTROL.sub("", chunk.decode("utf-8", errors="replace"))
        phrases = [match.group().lower() for match in PATTERN.finditer(text)]
        if phrases:
            diagnostics.append("; ".join(phrases)[:240])
            total += 1
        else:
            redacted = True
    if redacted:
        print("    output: [output redacted]")
    if total > len(diagnostics):
        print("    output: [additional output omitted]")
    for diagnostic in diagnostics:
        print("    output: " + diagnostic)


if __name__ == "__main__":
    main()
