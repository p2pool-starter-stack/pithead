# ruff: noqa: S603, S607
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CLOSING = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+(?:(?:https://github.com/)?([\w.-]+/[\w.-]+)(?:/issues/|#)|#)(\d+)\b",
    re.I,
)
PROOF = re.compile(r"^RC regression (RED|GREEN): (job|run) ([1-9][0-9]*)@([0-9a-f]{40})\s*$", re.M)


def validate(body, head, cwd):
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("invalid current head SHA")
    rows = PROOF.findall(body)
    red = [r for r in rows if r[0] == "RED"]
    green = [r for r in rows if r[0] == "GREEN"]
    if not red or not green:
        raise ValueError("RC-found fixes require RED and GREEN job/run references")
    if not any(r[3] == head for r in green):
        raise ValueError("GREEN proof must name the current head")
    for row in red:
        sha = row[3]
        if sha == head or any(row[1:3] == other[1:3] or sha == other[3] for other in green):
            raise ValueError("RED and GREEN must use distinct runs and SHAs")
        exists = subprocess.run(
            ["git", "cat-file", "-e", f"{sha}^{{commit}}"], cwd=cwd, capture_output=True
        )
        ancestor = subprocess.run(
            ["git", "merge-base", "--is-ancestor", sha, head], cwd=cwd, capture_output=True
        )
        if exists.returncode or ancestor.returncode:
            raise ValueError("RED SHA must resolve to a strict ancestor of the head")


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    pr = event["pull_request"]
    body = pr.get("body") or ""
    repo = event["repository"]["full_name"]
    issues = {
        int(number)
        for target, number in CLOSING.findall(body)
        if not target or target.lower() == repo.lower()
    }
    required = False
    for number in sorted(issues):
        result = subprocess.run(
            ["gh", "api", f"repos/{repo}/issues/{number}"],
            check=True,
            capture_output=True,
            text=True,
        )
        labels = json.loads(result.stdout)["labels"]
        required |= any(label["name"] == "rc-found" for label in labels)
    if required:
        validate(body, pr["head"]["sha"], Path.cwd())
        print("RC regression proof: PASS")
    else:
        print("RC regression proof: no closing rc-found issue")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print(f"RC regression proof: FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
