import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dashboard/mining_dashboard/service/logs/redact.sed"
SLICE = ROOT / "lib/pithead/07a-redact-patterns.sh"


def render() -> str:
    body = SOURCE.read_text().rstrip("\n")
    if "'" in body:
        raise SystemExit(f"{SOURCE.relative_to(ROOT)} must not contain a single quote")
    return f"# shellcheck shell=bash\nreadonly BUNDLE_REDACT_SED='{body}'\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = render()
    if args.check:
        if not SLICE.exists() or SLICE.read_text() != expected:
            print(f"Stale redaction patterns: {SLICE.relative_to(ROOT)}", file=sys.stderr)
            return 1
        return 0
    SLICE.write_text(expected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
