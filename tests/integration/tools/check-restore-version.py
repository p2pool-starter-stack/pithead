import json
import re
import sys
from pathlib import Path


def release(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}", value):
        raise ValueError
    return tuple(map(int, value.split(".")))


def main():
    try:
        candidate = re.split(r"[-+]", "".join(Path("VERSION").read_text().split()), maxsplit=1)[0]
        candidate_version = release(candidate)
        for config_path in sys.argv[1:] or ["config.json"]:
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
    except (OSError, ValueError, AttributeError, TypeError):
        print(
            "Restore compatibility unverified: require a readable configuration and valid candidate/configuration versions.",
            file=sys.stderr,
        )
        return 1
    print(f"Restore compatibility verified for candidate {candidate}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
