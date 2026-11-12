import json
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath


def check_bundle(archive, config_path, env_path):
    config = json.loads(Path(config_path).read_text())
    if config["telegram"].get("enabled") is not False:
        raise ValueError("Telegram fixture delivery is not disabled")
    secrets = [
        config["dashboard"]["auth"]["password"],
        config["p2pool"]["stratum_password"],
        config["telegram"]["bot_token"],
    ]
    if any(not isinstance(value, str) or len(value) < 16 for value in secrets):
        raise ValueError("credential fixture is not armed")
    env = Path(env_path).read_bytes()
    for key, value in (("PROXY_STRATUM_PASSWORD", secrets[1]), ("TELEGRAM_BOT_TOKEN", secrets[2])):
        if not any(
            line.startswith(key.encode() + b"=") and value.encode() in line
            for line in env.splitlines()
        ):
            raise ValueError("rendered credential fixture is not armed")
    if stat.S_IMODE(Path(archive).stat().st_mode) != 0o600:
        raise ValueError("archive mode is not 600")
    files = {}
    with tarfile.open(archive, "r:gz") as bundle:
        total = 0
        for member in bundle:
            if any(value in member.name for value in secrets):
                raise ValueError("archive member name contains a fixture credential")
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or name.parts[:1] != ("bundle",):
                raise ValueError("unexpected archive member path")
            if member.isdir():
                continue
            if not member.isfile() or member.name in files:
                raise ValueError("unexpected archive member type or duplicate")
            total += member.size
            if total > 64 * 1024 * 1024:
                raise ValueError("archive exceeds the inspection bound")
            content = bundle.extractfile(member).read()
            if any(value.encode() in content for value in secrets):
                raise ValueError("archive contains a fixture credential")
            files[member.name] = content
    required = {
        "host.txt",
        "doctor.json",
        "doctor.txt",
        "config.masked.json",
        "env.redacted",
        "compose-ps.txt",
    }
    if any(not files.get("bundle/" + name) for name in required):
        raise ValueError("archive is missing diagnostic content")
    doctor = json.loads(files["bundle/doctor.json"])
    if not doctor.get("checks") or not isinstance(doctor.get("summary"), dict):
        raise ValueError("doctor report is incomplete")
    masked = json.loads(files["bundle/config.masked.json"])
    for value in (
        masked["dashboard"]["auth"]["password"],
        masked["p2pool"]["stratum_password"],
        masked["telegram"]["bot_token"],
    ):
        if value != {"__secret__": True}:
            raise ValueError("config credential is not masked")
    redacted = files["bundle/env.redacted"].decode()
    for key in ("PROXY_STRATUM_PASSWORD", "TELEGRAM_BOT_TOKEN", "DASHBOARD_AUTH_HASH_B64"):
        if key + "=[redacted]" not in redacted.splitlines():
            raise ValueError("rendered credential is not redacted")
    if not any(
        name.startswith("bundle/logs/") and content.strip() for name, content in files.items()
    ):
        raise ValueError("archive has no real log tails")
    if b"container engine not reachable" in files["bundle/compose-ps.txt"]:
        raise ValueError("archive has no live Compose census")


if __name__ == "__main__":
    try:
        check_bundle(*sys.argv[1:])
    except Exception:
        print("support-bundle inspection failed; sensitive contents withheld", file=sys.stderr)
        sys.exit(1)
    print("support-bundle permissions, diagnostics and credential redaction verified")
