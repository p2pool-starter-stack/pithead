import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from hardening_onion_fixture import BASE_ENV, BASELINE, DOCKER, DRIVER, PITHEAD, SUDO

REACH = "dashboard onion reachable from an independent external Tor client (#343/#360)"
RECOVER = "dashboard onion reachable from outside AFTER the tor restart (#424 recovery)"
KEYLESS = "dashboard onion refuses an independent client without a key (#2603)"
KEY_ERROR = "dashboard onion authorized probe obtains CLI credentials (#2603)"
RESTORED = "dashboard onion identity and environment restored exactly (#2603)"
UNITS = "control systemd units removed after the hardening phase (#477)"
SKIP_LEG = "dashboard onion external reachability"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
ROW = re.compile(r"^\s*(✓|✗) (.*)$")
BENCH = (
    "B1 tier4-e2e hardening job on the PR head: completed, baseline_verified, evidence and manifest name HEAD",
    "B2 authorized reachability, keyless refusal, recovery and control-unit cleanup execute and pass",
)
results = []


def report(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout  # noqa: S603, S607


def parse_rows(text):
    rows = []
    for ln in text.splitlines():
        m = ROW.match(ANSI.sub("", ln).rstrip())
        if m:
            rows.append(("pass" if m[1] == "✓" else "fail", m[2].strip()))
    return rows


def drive(
    fail_on="",
    client_fail="",
    client_empty="",
    bootstrap_on="",
    error_on="",
    keyless="",
    apply_fail="0",
    interrupt="0",
    restore_fail="0",
    entry_auth=True,
    tor_start_fail="0",
):
    with tempfile.TemporaryDirectory() as stub:
        s = Path(stub).resolve()
        box = s / "box"
        box.mkdir()
        entry = json.loads(json.dumps(BASELINE))
        entry["dashboard"]["onion"]["client_auth"] = entry_auth
        (box / "config.json").write_text(json.dumps(entry) + "\n")
        entry_env = BASE_ENV.replace(
            "DASHBOARD_ONION_CLIENT_AUTH=true",
            f"DASHBOARD_ONION_CLIENT_AUTH={str(entry_auth).lower()}",
        )
        (box / ".env").write_text(entry_env + f"TOR_DATA_DIR={box / 'tor'}\n")
        (box / ".env").chmod(0o600)
        (box / "tor").mkdir()
        helper = box / "tests/integration/lib/hardening_onion_state.py"
        helper.parent.mkdir(parents=True)
        helper.write_text(Path("tests/integration/lib/hardening_onion_state.py").read_text())
        for name in ("10-installer-preseed.sh", "50-control-runner-provisioning.sh"):
            source = Path("lib/pithead") / name
            target = box / source
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        before_env = (box / ".env").read_bytes()
        for path, body in (
            (box / "pithead", PITHEAD),
            (s / "docker", DOCKER),
            (s / "systemctl", "#!/usr/bin/env bash\nexit 0\n"),
            (s / "sudo", SUDO),
        ):
            path.write_text(body)
            path.chmod(0o755)
        env = {
            **os.environ,
            "STUB": stub,
            "PROBE_FAIL_ON": fail_on,
            "CLIENT_FAIL_ON": client_fail,
            "CLIENT_EMPTY_ON": client_empty,
            "PROBE_BOOTSTRAP_ON": bootstrap_on,
            "PROBE_ERROR_ON": error_on,
            "KEYLESS_RESULT": keyless,
            "APPLY_FAIL": apply_fail,
            "INTERRUPT_PROBE": interrupt,
            "RESTORE_FAIL_ONCE": restore_fail,
            "RUN_BASELINE_CONFIG": json.dumps(BASELINE),
            "TOR_START_FAIL": tor_start_fail,
        }
        r = subprocess.run(  # noqa: S603
            ["bash", "-c", DRIVER],  # noqa: S607
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )
        out = ANSI.sub("", r.stdout + r.stderr)
        events = (s / "events.log").read_text().splitlines() if (s / "events.log").exists() else []
        final = json.loads((box / "config.json").read_text() or "null")
        restored_state = (
            (box / ".env").read_bytes() == before_env
            and not (box / "tor/dashboard").exists()
            and not list(box.glob(".hardening-onion-*"))
            and not list(box.glob("backups/.hardening-onion-*"))
        )
    err = re.search(r"DRIVER-ERROR: .*", out)
    return {
        "rows": parse_rows(out),
        "out": out,
        "events": events,
        "final": final,
        "restored_state": restored_state,
        "returncode": r.returncode,
        "error": err[0] if err else "",
    }


def verdicts(run, name):
    return [v for v, t in run["rows"] if t == name]


def probes(events):
    return [
        (i, dict(kv.split("=", 1) for kv in e.split()[2:]))
        for i, e in enumerate(events)
        if e.startswith("probe ")
    ]


parser = argparse.ArgumentParser()
parser.add_argument("--results", type=Path)
parser.add_argument("--base-ref", default="origin/develop")
parser.add_argument("--selftest", action="store_true")
args = parser.parse_args()

if not args.selftest:
    base = git("merge-base", args.base_ref, "HEAD").strip()
    head = git("rev-parse", "HEAD").strip()
    changed = set(git("diff", "--name-only", base).split())
    outside = sorted(
        f
        for f in changed
        if not f.startswith(("tests/integration/", "docs/")) and f != "CHANGELOG.md"
    )
    report(
        "C1 changes touch tests/integration/ and stay in it and docs/ (CHANGELOG.md allowed)",
        not outside and any(f.startswith("tests/integration/") for f in changed),
        f"changed: {sorted(changed)}",
    )

A, B = drive(), drive(fail_on="1")
names = [
    "C2 on a box with no onion, the phase passes the reachability row and does not skip the onion leg",
    "C3 the first probe follows an apply with onion enabled, client_auth true and control on, and dials "
    "the provisioned onion with its client key",
    "C4 each authorized probe gets fresh CLI credentials; the keyless probe is clean; hardening reads no private key directly",
    "C5 tor is restarted after the first probe, a later probe runs, and the #424 recovery row passes",
    "C6 the phase ends on the baseline: config.json restored exactly, last apply has the onion off, units removed",
    "C7 the first probe failing (live Tor flake): a probe ran, no onion row fails, recovery is not asserted",
]
if A["error"] or B["error"]:
    for n in names:
        report(n, False, A["error"] or B["error"])
else:
    ev, pr = A["events"], probes(A["events"])
    skipped = re.search(rf"skipped leg {re.escape(SKIP_LEG)}", A["out"]) is not None
    report(
        names[0],
        verdicts(A, REACH) == ["pass"] and not skipped,
        f"reachability verdicts {verdicts(A, REACH)}, onion leg skipped {skipped}",
    )
    first = pr[0] if pr else None
    applies = [e for e in ev[: first[0]] if e.startswith("apply ")] if first else []
    report(
        names[1],
        bool(first)
        and applies[-1:] == ["apply onion=true client_auth=true control=true"]
        and first[1].get("onion") == "provisioned"
        and first[1].get("keyed") == "yes"
        and "apply-result ok" in ev[: first[0]]
        and "apply-result failed" not in ev[: first[0]],
        f"last apply before it {applies[-1:]}, first probe {first[1] if first else None}",
    )
    authorized = [(i, p) for i, p in pr if p.get("keyed") == "yes"]
    fresh = all(
        [
            e
            for e in ev[max((j for j, _ in pr if j < i), default=-1) + 1 : i]
            if e.startswith("client-key ")
        ]
        == ["client-key ok"]
        for i, _ in authorized
    )
    keyless = [(i, p) for i, p in pr if p.get("keyed") == "no"]
    probe_source = Path("tests/integration/lib/run-onion-targets.sh").read_text()
    hardening_probe = re.sub(r"    auto\)\n.*?        ;;\n", "", probe_source, flags=re.S)
    readers = "DASHBOARD_ONION_CLIENT_PRIVKEY" in (
        Path("tests/integration/lib/run-hardening.sh").read_text() + hardening_probe
    )
    report(
        names[2],
        len(authorized) == 3
        and fresh
        and len(keyless) == 1
        and keyless[0][1].get("clean") == "yes"
        and not readers,
        f"authorized probes {len(authorized)}, fresh CLI reads {fresh}, clean keyless probes "
        f"{sum(p.get('clean') == 'yes' for _, p in keyless)}, hardening direct reader {readers}",
    )
    restart = [i for i, e in enumerate(ev) if e == "restart tor"]
    later = bool(pr) and any(r > pr[0][0] and any(i > r for i, _ in pr) for r in restart)
    report(
        names[3],
        later and verdicts(A, RECOVER) == ["pass"],
        f"restart then probe {later}, recovery verdicts {verdicts(A, RECOVER)}",
    )
    last_apply = [e for e in ev if e.startswith("apply ")][-1:]
    report(
        names[4],
        A["final"] == BASELINE
        and A["restored_state"]
        and last_apply
        and last_apply[0].startswith("apply onion=false")
        and verdicts(A, UNITS) == ["pass"]
        and verdicts(A, RESTORED) == ["pass"],
        f"config restored {A['final'] == BASELINE}, last apply {last_apply}, units {verdicts(A, UNITS)}",
    )
    onion_red = [t for v, t in B["rows"] if v == "fail" and "onion" in t.lower()]
    report(
        names[5],
        len(probes(B["events"])) >= 1 and not onion_red and not verdicts(B, RECOVER),
        f"probes {len(probes(B['events']))}, failing onion rows {onion_red}, recovery verdicts {verdicts(B, RECOVER)}",
    )

report("C8 a clean client without credentials is refused", verdicts(A, KEYLESS) == ["pass"])
for label, kwargs in (
    ("failed first CLI read despite valid output", {"client_fail": "1"}),
    ("empty first CLI output", {"client_empty": "1"}),
    ("failed second CLI read despite valid output", {"client_fail": "2"}),
    ("empty second CLI output", {"client_empty": "2"}),
    ("failed final CLI read despite valid output", {"client_fail": "3"}),
    ("empty final CLI output", {"client_empty": "3"}),
):
    run = drive(**kwargs)
    report(
        f"C9 {label} fails an onion row and restores baseline",
        any(v == "fail" and "onion" in t for v, t in run["rows"])
        and len(probes(run["events"])) == (0 if next(iter(kwargs.values())) == "1" else 3)
        and run["final"] == BASELINE
        and run["restored_state"],
    )
for label, kwargs, row in (
    ("keyless access succeeds", {"keyless": "reachable"}, KEYLESS),
    ("keyless bootstrap fails", {"keyless": "bootstrap"}, KEYLESS),
    ("keyless infrastructure fails", {"keyless": "error"}, KEYLESS),
    ("authorized control after keyless probe fails", {"fail_on": "3"}, KEYLESS),
):
    run = drive(**kwargs)
    report(
        f"C10 {label} fails its row and restores baseline",
        verdicts(run, row) == ["fail"]
        and run["final"] == BASELINE
        and run["restored_state"]
        and (
            kwargs.get("fail_on") != "3"
            or "authorized control failed after the keyless probe (exit 1; keyless exit 1)"
            in run["out"]
        ),
    )

for label, kwargs, stage, code in (
    ("HTTP unreachable", {"fail_on": "4"}, "http-unreachable", 1),
    ("bootstrap", {"bootstrap_on": "4"}, "bootstrap", 2),
    ("client error", {"error_on": "4"}, "client-error", 3),
    ("credentials", {"client_fail": "3"}, "credentials", 4),
):
    run = drive(**kwargs)
    diagnostic = f"external client probe failed (stage {stage}; exit {code})"
    report(
        f"C10 post-restart {label} failure is categorical and restores baseline",
        verdicts(run, RECOVER) == ["fail"]
        and diagnostic in run["out"]
        and "PROBE-SECRET-SENTINEL" not in run["out"]
        and "CLIENT-CREDENTIAL-SECRET-SENTINEL" not in run["out"]
        and run["final"] == BASELINE
        and run["restored_state"],
    )

run = drive(apply_fail="1")
report(
    "C11 failed provisioning apply never probes and restores baseline",
    any(v == "fail" and "onion" in t for v, t in run["rows"])
    and not probes(run["events"])
    and run["final"] == BASELINE
    and run["restored_state"],
)

run = drive(interrupt="1")
report(
    "C12 interrupted hardening restores exact environment and identity",
    run["returncode"] != 0 and run["final"] == BASELINE and run["restored_state"],
)

run = drive(restore_fail="1")
report(
    "C13 failed normal restore is reported and EXIT safely completes restoration",
    verdicts(run, RESTORED) == ["fail"] and run["restored_state"] and run["final"] == BASELINE,
)

run = drive(entry_auth=False)
report(
    "C14 restoration uses the captured phase-entry configuration when the run baseline differs",
    verdicts(run, RESTORED) == ["pass"]
    and run["restored_state"]
    and run["final"]["dashboard"]["onion"]["client_auth"] is False,
)

run = drive(tor_start_fail="1")
report(
    "C15 a failed Tor restore start fails the row and retains protected recovery copies",
    verdicts(run, RESTORED) == ["fail"]
    and not run["restored_state"]
    and "hardening onion restore failed at tor-start" in run["out"],
)

if args.selftest:
    pass
elif args.results is None:
    for n in BENCH:
        report(n, False, "bench evidence not supplied")
else:
    d = args.results
    p = d / "evidence.json"
    ev = json.loads(p.read_text()) if p.is_file() else {}
    ev = ev.get("evidence", ev)
    man = d / "results" / "manifest.txt"
    rev = (
        re.search(r"^git_rev:\s*([0-9a-f]+)\s*$", man.read_text(), re.M) if man.is_file() else None
    )
    phases = (ev.get("options") or {}).get("phases")
    report(
        BENCH[0],
        ev.get("commit") == head
        and ev.get("tier") == "tier4-e2e"
        and ev.get("status") == "completed"
        and phases == ["hardening"]
        and ev.get("baseline_verified") is True
        and rev is not None
        and len(rev[1]) >= 7
        and head.startswith(rev[1]),
        f"commit {str(ev.get('commit'))[:12]}, tier {ev.get('tier')}, status {ev.get('status')}, phases {phases}, "
        f"baseline_verified {ev.get('baseline_verified')}, manifest git_rev {rev[1] if rev else None}",
    )
    log = d / "e2e-harness.log"
    text = ANSI.sub("", log.read_text(errors="replace")) if log.is_file() else ""
    run = {"rows": parse_rows(text)}
    skipped = re.search(rf"^\s*- \[[a-z-]+\] leg\s+{re.escape(SKIP_LEG)}", text, re.M) is not None
    r, c, u, k, restored = (
        verdicts(run, name) for name in (REACH, RECOVER, UNITS, KEYLESS, RESTORED)
    )
    report(
        BENCH[1],
        "pass" in r
        and "fail" not in r
        and "pass" in c
        and "fail" not in c
        and not skipped
        and "pass" in u
        and "fail" not in u
        and "pass" in k
        and "fail" not in k
        and "pass" in restored
        and "fail" not in restored,
        f"reachability {r}, keyless refusal {k}, recovery {c}, onion leg skipped {skipped}, units {u}, exact restoration {restored}",
    )

print(
    f"\n{('SELFTEST PASS' if args.selftest else 'ACCEPTED') if all(results) else 'NOT ACCEPTED'}: {sum(results)}/{len(results)} checks pass"
)
sys.exit(0 if all(results) else 1)
