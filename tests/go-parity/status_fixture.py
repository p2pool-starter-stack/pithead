import json
import os
import sys
from pathlib import Path

model = json.loads(Path(os.environ["STATUS_FIXTURE"]).read_text())
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
services = model.get("services", {"caddy": "running:none"})
ids = {name: f"{index + 1:064x}" for index, name in enumerate(services)}

if tool in ("docker", "podman"):
    if args == ["compose", "ps"]:
        print("fixture compose table")
    elif args == ["compose", "config", "--services"]:
        print("\n".join(services))
    elif args == ["compose", "ps", "-aq"]:
        print("\n".join(ids[name] for name in services if services[name] != "missing"))
    elif args[:3] == ["compose", "ps", "-aq"]:
        if services.get(args[3], "missing") != "missing":
            print(args[3])
    elif args[:2] == ["inspect", "--format"]:
        if "RestartCount" in args[2]:
            counter = Path(os.environ["STATUS_COUNTER"])
            count = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(count))
            if model.get("bad_snapshot"):
                print("not-a-snapshot")
            else:
                for name, identity in ids.items():
                    if services[name] == "missing":
                        continue
                    state = services[name].split(":")[0]
                    restarts = count if model.get("restart") == name else 0
                    print(f"{identity}\t/{name}\t{state}\t{restarts}\t2026-10-01T00:00:00Z")
        else:
            print(services[args[-1]].replace(":", " "))
    else:
        sys.exit(2)
elif tool == "curl":
    if model.get("dashboard") is not None:
        print(json.dumps(model["dashboard"]))
    sys.exit(model.get("curl_exit", 0))
elif tool == "openssl":
    print("sha256 Fingerprint=" + ":".join(["AB"] * 32))
else:
    sys.exit(2)
