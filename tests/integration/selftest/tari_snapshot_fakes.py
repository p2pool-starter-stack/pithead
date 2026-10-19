#!/usr/bin/env python3
import json
import os
import shutil
import sys
from pathlib import Path

root = Path(os.environ["SNAPSHOT_FIXTURE"])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "commands").open("a") as stream:
    stream.write(tool + " " + " ".join(args) + "\n")

if tool == "sudo":
    args.remove("-n")
    tool, args = args[0], args[1:]


def interrupt():
    if tool != os.environ.get("INTERRUPT_TOOL") or (tool == "docker" and args[0] != "stop"):
        return
    counter = root / (tool + ".counter")
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if count == int(os.environ["INTERRUPT_COUNT"]):
        import signal

        os.kill(
            int((root / "work" / "worker.pid").read_text()),
            getattr(signal, os.environ["INTERRUPT_SIGNAL"]),
        )
        raise SystemExit(143)


if os.environ.get("INTERRUPT_BEFORE"):
    interrupt()

if tool == "cp":
    if "--reflink=always" in args and os.environ.get("REFLINK_FAIL"):
        raise SystemExit(1)
    source, target = map(Path, args[-2:])
    if source.is_dir():
        shutil.copytree(source, target)
    else:
        shutil.copy2(source, target)
elif tool == "mv":
    os.rename(args[-2], args[-1])
elif tool == "rm":
    if os.environ.get("RM_FAIL"):
        raise SystemExit(1)
    for name in args[args.index("--") + 1 :]:
        item = Path(name)
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink(missing_ok=True)
elif tool == "du":
    print("128\t" + args[-1])
elif tool == "find":
    print(sum(p.stat().st_size for p in Path(args[0]).rglob("*.mdb")))
elif tool == "df":
    print("Avail\n" + os.environ.get("FIXTURE_FREE", "1000000000000"))
elif tool == "sync":
    pass
elif tool == "docker":
    state = json.loads((root / "docker.json").read_text())
    if args[0] == "inspect":
        item = state[args[-1]]
        if "-f" in args:
            print(str(item["State"]["Running"]).lower() + " false")
        else:
            print(json.dumps([item]))
    elif args[0] in {"stop", "start", "restart"}:
        item = state[args[-1]]
        item["State"]["Running"] = args[0] != "stop"
        if args[0] == "restart":
            item["State"]["StartedAt"] = "restarted"
            import time

            metrics_file = root / "work" / "metrics.json"
            metrics = json.loads(metrics_file.read_text())
            metrics.setdefault("migration_starts", {})[item["Id"] + "@restarted"] = False
            metrics_file.write_text(json.dumps(metrics))
            (root / "work" / "migration.json").write_text(
                json.dumps(
                    {
                        "active": False,
                        "sampled_at": time.time(),
                        "container": item["Id"],
                        "started": "restarted",
                        "wallet": "tari-wallet",
                        "wallet_started": "baseline",
                    }
                )
            )
        (root / "docker.json").write_text(json.dumps(state))
    elif args[0] == "exec":
        if "GetNetworkState" in args[-1]:
            print(json.dumps({"ready": True, "migration": False, "phase": "READY"}))
        elif "sh" in args:
            (root / "node" / args[-1]).write_text("branch marker")
        elif "test" in args:
            name = args[-1].rsplit("/", 1)[-1]
            raise SystemExit(int((root / "node" / name).exists()))
    elif args[0] == "logs":
        print("normal clean startup")
    elif args[0] == "ps":
        pass
    else:
        raise SystemExit(1)
else:
    raise SystemExit(1)

if not os.environ.get("INTERRUPT_BEFORE"):
    interrupt()
