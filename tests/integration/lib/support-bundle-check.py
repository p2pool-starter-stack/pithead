import json
import stat
import sys
import tarfile
from pathlib import Path


def check_bundle(archive, secrets):
    if len(secrets) != 3 or any(not isinstance(s, str) or len(s) < 8 for s in secrets):
        raise ValueError("three nonempty fixture credentials are required")
    if stat.S_IMODE(archive.stat().st_mode) != 0o600:
        raise ValueError("archive mode is not 600")
    with tarfile.open(archive, "r:gz") as bundle:
        files = {}
        names = set()
        for member in bundle.getmembers():
            if member.name in names or any(secret in member.name for secret in secrets):
                raise ValueError("duplicate or credential-bearing bundle member name")
            names.add(member.name)
            if not member.isdir() and not member.isfile():
                raise ValueError("unexpected non-regular bundle member")
            if member.isfile():
                files[member.name] = bundle.extractfile(member).read()
    required = (
        "host.txt",
        "doctor.json",
        "doctor.txt",
        "config.masked.json",
        "env.redacted",
        "compose-ps.txt",
    )
    if any(not files.get("bundle/" + name) for name in required):
        raise ValueError("missing or empty diagnostic member")
    doctor = json.loads(files["bundle/doctor.json"])
    if not doctor.get("checks") or not isinstance(doctor.get("summary"), dict):
        raise ValueError("doctor report has no checks or summary")
    config = json.loads(files["bundle/config.masked.json"])
    for parent, key in (
        ("dashboard", "auth"),
        ("p2pool", "stratum_password"),
        ("telegram", "bot_token"),
    ):
        value = config[parent][key]
        if parent == "dashboard":
            value = value["password"]
        if value != {"__secret__": True}:
            raise ValueError("config credential is not masked")
    for key in ("DASHBOARD_AUTH_HASH_B64", "PROXY_STRATUM_PASSWORD", "TELEGRAM_BOT_TOKEN"):
        if (key + "=[redacted]").encode() not in files["bundle/env.redacted"].splitlines():
            raise ValueError("rendered credential is not redacted")
    if not any(name.startswith("bundle/logs/") and content for name, content in files.items()):
        raise ValueError("no live log tail collected")
    if any(secret.encode() in content for secret in secrets for content in files.values()):
        raise ValueError("fixture credential leaked into a bundle member")


if __name__ == "__main__":
    try:
        check_bundle(Path(sys.argv[1]), json.load(sys.stdin))
    except (OSError, ValueError, KeyError, tarfile.TarError):
        print("support bundle verification failed (details withheld)", file=sys.stderr)
        sys.exit(1)
    print("mode, diagnostic members, masked config, live logs and credential absence verified")
