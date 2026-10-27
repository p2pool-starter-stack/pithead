import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RIG_MIN = 77

STACK_MIN_RUN = 6000

IP_CAUSED = [
    "a broken-rig failure mentioning the throttle stays 'failed', never calmed",
    "a confirmed LAN hostname append is adopted",
    "a confirmed adopt appends rig-2 after rig-1",
    "a confirmed ordinary LAN append is adopted",
    "a failed apply reaches terminal 'failed', not the poll-deadline 'accepted'",
    "a first-class 'throttled' terminal lands as retry-later on the first poll",
    "a fresh derive parses tag_name and drives the upgrade to applied",
    "a malformed rig change ID fails before status polling",
    "a non-latest proposal is refused against the host-derived tag",
    "a release API response with no usable tag refuses fail-closed",
    "a rig already on the target lands first-class 'noop', not the poll-cap fallback",
    "a rig non-202 (incl. an old-rig < v1.11.2 refusal) is surfaced as rejected",
    "a stale terminal for a PREVIOUS change_id is ignored; ours lands",
    "an adopt preview is a destructive, typed-APPLY change",
    "an unreachable GitHub release API refuses fail-closed",
    "an unreachable rig fails cleanly (nothing changed)",
    "applied result records the host-derived version",
    "applied result records the rig's change_id",
    "config.json gains rig3 after rig1, rig1 untouched",
    "config.json gains the LAN hostname as the third rig",
    "config.json still has exactly rig1 and rig3 after every round-5 SSRF refusal above",
    "empty changes rejected",
    "hitting the poll cap lands 'accepted' (queued on the rig), not a failure",
    "legacy rig (pre-v1.12.0) throttle refusal (failed+text) still maps to retry-later",
    "non-writable key rejected",
    "rolled_back result carries the rig's reason",
    "the adopt audit names worker and env rows",
    "the adopt commit is audited as confirmed and names workers.list",
    "the adopt warning names the rig and its address",
    "the derived tag is cached for the next intent",
    "the failed apply carries the rig's reason",
    "the failed apply is audited as failed",
    "the failed reason parse control fired",
    "the noop result carries the rig's already-on-target reason",
    "the poll-cap timeout is audited as accepted",
    "the stale terminal was polled past, not accepted",
    "the timed-out result says the upgrade is still running",
    "the unconfirmed append asks for APPLY and names the rig",
    "upgrade accept path reaches a terminal 'applied'",
    "upgrade applied is audited",
    "upgrade inside the 10-min lookup window (no cached tag) is rejected",
    "upgrade over the per-drain budget is rejected (no dial)",
    "upgrade rollback surfaces as rolled_back",
    "upgrade: bare (non-tag) version rejected",
    "worker-apply accept is audited as applied",
    "worker-apply accept path reaches a terminal 'applied' status",
    "worker-apply accept path records the rig's change_id",
    "worker-apply accept path records the rig's changed_keys",
    "worker-apply gives curl its bearer through stdin config",
    "worker-apply over the dial budget is rejected (no dial)",
    "worker-upgrade gives curl its bearer through stdin config",
    "worker-upgrade rig dials carry a --max-filesize cap (#690)",
]

RIG_RUNNER = 'make -s pithead >/dev/null && set -uo pipefail && source tests/stack/lib.sh && source tests/stack/test-rig-worker.sh; echo "TALLY PASS=$PASS FAIL=$FAIL"'

ANSI = re.compile("\\x1b\\[[0-9;]*m")

DOCKERFILE = Path("tests/runner/Dockerfile")
ALLOWED = {
    str(DOCKERFILE),
    ".github/workflows/test-runner-acceptance.yml",
    "tests/runner/accept-iproute2.py",
    "docs/dev/testing-strategy.md",
}
CONTAINER = ["bash", "scripts/test-container.sh"]


def stack_result(out):
    total = re.search(r"^pithead tests: (\d+) passed, (\d+) failed", out, re.M)
    ran = int(total.group(1)) + int(total.group(2)) if total else 0
    marks = {"✓": set(), "✗": set()}
    for line in out.splitlines():
        text = line.strip()
        if text[:1] in marks:
            marks[text[:1]].add(text[1:].strip())
    failed = sorted(n for n in IP_CAUSED if n in marks["✗"])
    missing = sorted(n for n in IP_CAUSED if n not in marks["✓"])
    return ran, failed, missing


def redact(text):
    text = ANSI.sub("", text)
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<address>", text)
    text = re.sub(r"(?<![\w:])(?:[\da-fA-F]*:){2,}[\da-fA-F:.%]*", "<address>", text)
    text = re.sub(r"/(?:home|Users)/[^\s/]+", "<home>", text)
    return re.sub(r"\b[\w.-]+\.(?:lan|local|internal)\b", "<host>", text)


def self_test():
    all_pass = "\n".join("✓ " + n for n in IP_CAUSED)
    summary = f"\npithead tests: {STACK_MIN_RUN - 6} passed, 6 failed\n"
    out = all_pass + "\n✗ unrelated missing tool" + summary
    check = unittest.TestCase()
    check.assertEqual(stack_result(out), (STACK_MIN_RUN, [], []))
    check.assertEqual(stack_result(out + "\n✗ " + IP_CAUSED[0])[1], [IP_CAUSED[0]])
    check.assertEqual(
        stack_result(out.replace("✓ " + IP_CAUSED[0], "SKIP " + IP_CAUSED[0]))[2],
        [IP_CAUSED[0]],
    )
    check.assertEqual(stack_result(all_pass)[0], 0)
    check.assertLess(
        stack_result(all_pass + "\npithead tests: 5999 passed, 0 failed")[0], STACK_MIN_RUN
    )
    check.assertEqual(
        redact("fixture 192.0.2.1 and 2001:db8::1"), "fixture <address> and <address>"
    )
    check.assertEqual(redact("/home/user/log box.internal"), "<home>/log <host>")
    print("accept-iproute2 self-test: passed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="origin/develop-v2.1.0")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--missing-iproute2", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    output = args.output or Path(tempfile.mkdtemp(prefix="accept-iproute2-"))
    output.mkdir(parents=True, exist_ok=True)
    git_bin = shutil.which("git")
    bash_bin = shutil.which("bash")
    if not git_bin or not bash_bin:
        raise RuntimeError("git and bash are required")

    def git(*command):
        return subprocess.check_output([git_bin, *command], text=True).strip()  # noqa: S603

    head = git("rev-parse", "HEAD")
    base = git("merge-base", "--", args.base, "HEAD")
    changed = set(git("diff", "--name-only", base, "--").splitlines())
    results = []
    transcript = []
    commands = []

    def emit(line):
        print(line, flush=True)
        transcript.append(line)
        (output / "acceptance.txt").write_text("\n".join(transcript) + "\n")

    def report(name, ok, detail=""):
        results.append(ok)
        emit(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

    def container(label, *cmd):
        command = [bash_bin, *CONTAINER[1:], *cmd]
        with tempfile.TemporaryFile("w+") as capture:
            try:
                rc = subprocess.run(  # noqa: S603
                    command, stdout=capture, stderr=subprocess.STDOUT, timeout=3600, check=False
                ).returncode
            except subprocess.TimeoutExpired:
                rc = 124
            capture.seek(0)
            out = ANSI.sub("", capture.read())
        (output / f"{label}.log").write_text(redact(out))
        commands.append({"command": command, "exit": rc})
        return rc, out

    emit(f"Commit: {head}")
    emit(f"Merge base: {base}")
    emit("Image: missing-iproute2 control" if args.missing_iproute2 else "Image: PR head")
    report(
        "C1 tests/runner/Dockerfile changes, and only the four allowed paths differ",
        str(DOCKERFILE) in changed and changed <= ALLOWED,
        f"changed: {sorted(changed)}",
    )
    original = DOCKERFILE.read_text()
    if args.missing_iproute2:
        if original.count(" iproute2 ") != 1:
            raise ValueError("control requires exactly one iproute2 package in the Dockerfile")
        DOCKERFILE.write_text(original.replace(" iproute2 ", " ", 1))
    dockerfile_sha = hashlib.sha256(DOCKERFILE.read_bytes()).hexdigest()
    try:
        rc, _ = container("C2-build", "--build", "true")
        report("C2 the test image rebuilds from this head's Dockerfile", rc == 0, f"exit {rc}")
        rc, out = container("C3-ip", "ip", "-o", "-4", "addr", "show")
        inet = [line for line in out.splitlines() if " inet " in line]
        report(
            "C3 `ip -o -4 addr show` works in the image and lists an address",
            rc == 0 and len(inet) >= 1,
            f"exit {rc}, {len(inet)} inet line(s)",
        )
        rc, out = container("C4-rig", "bash", "-c", RIG_RUNNER)
        match = re.search(r"^TALLY PASS=(\d+) FAIL=(\d+)$", out, re.M)
        passed, failed = (int(match.group(1)), int(match.group(2))) if match else (0, -1)
        report(
            f"C4 tests/stack/test-rig-worker.sh passes in the image (>= {RIG_MIN} assertions, 0 failed)",
            passed >= RIG_MIN and failed == 0,
            f"{passed} passed, {failed} failed",
        )
        rc, out = container("C5-stack", "make", "test-stack")
        ran, still_failing, never_passed = stack_result(out)
        report(
            f"C5 make test-stack in the image: all {len(IP_CAUSED)} `ip`-dependent assertions pass and none fails "
            f"(>= {STACK_MIN_RUN} assertions ran)",
            ran >= STACK_MIN_RUN and not still_failing and not never_passed,
            f"{ran} ran; still failing {len(still_failing)}: {still_failing[:3]}; "
            f"never passed {len(never_passed)}: {never_passed[:3]}",
        )
    finally:
        if args.missing_iproute2:
            DOCKERFILE.write_text(original)
    good = sum(results)
    emit(
        f"\n{'ACCEPTED' if good == len(results) else 'NOT ACCEPTED'}: {good}/{len(results)} checks pass"
    )
    control_ok = (
        args.missing_iproute2
        and results == [True, True, False, False, False]
        and commands[-1]["exit"] != 124
        and ran >= STACK_MIN_RUN
        and bool(still_failing)
    )
    if args.missing_iproute2:
        emit("CONTROL CONFIRMED" if control_ok else "CONTROL FAILED TO REPRODUCE")
    record = {
        "commit": head,
        "dockerfile_sha256": dockerfile_sha,
        "acceptance_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "base": base,
        "missing_iproute2": args.missing_iproute2,
        "results": results,
        "commands": commands,
        "control_confirmed": control_ok,
    }
    (output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    return 0 if control_ok or (not args.missing_iproute2 and all(results)) else 1


if __name__ == "__main__":
    sys.exit(main())
