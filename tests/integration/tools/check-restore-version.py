import json
import os
import re
import sys
from pathlib import Path


def release(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}", value):
        raise ValueError
    return tuple(map(int, value.split(".")))


def admission_paths(canonical, candidate):
    root = Path(candidate).resolve()
    canonical = Path(canonical)
    live = canonical.parent / "current"
    seed = live.resolve(strict=True) if live.exists() or live.is_symlink() else canonical
    paths = []
    for directory in (seed, canonical):
        for name in ("config.json", ".env"):
            target = (directory / name).resolve(strict=True)
            if (
                root == target
                or root in target.parents
                or not target.is_file()
                or not os.access(target, os.R_OK)
            ):
                raise ValueError
            if name == "config.json":
                paths.append(target)
    return paths


def main():
    try:
        args = sys.argv[1:]
        if args[:1] == ["--admission"]:
            if len(args) != 4:
                raise ValueError
            version = args[1]
            config_paths = admission_paths(args[2], args[3])
        else:
            version = Path("VERSION").read_text()
            config_paths = args or ["config.json"]
        candidate = re.split(r"[-+]", "".join(version.split()), maxsplit=1)[0]
        candidate_version = release(candidate)
        for config_path in config_paths:
            config = json.loads(Path(config_path).read_text())
            stamp = config.get("config_version", "2.0.0")
            if stamp is None or stamp is False:
                stamp = "2.0.0"
            baseline_version = release(stamp)
            if baseline_version > candidate_version:
                print(
                    f"Restore compatibility refused: configuration {stamp} is newer than candidate {candidate}. "
                    f"Use a candidate {stamp} or later, or a compatible isolated baseline; "
                    "the newer-configuration restore guard must remain enforced.",
                    file=sys.stderr,
                )
                return 1
    except (OSError, ValueError, AttributeError, TypeError, RuntimeError):
        print(
            "Restore compatibility unverified: require a readable configuration and valid candidate/configuration versions.",
            file=sys.stderr,
        )
        return 1
    print(f"Restore compatibility verified for candidate {candidate}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
