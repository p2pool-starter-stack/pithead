import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "dashboard"))


def artifacts() -> dict[Path, str]:
    from mining_dashboard.config.defaults import (
        TABLE,
        effective_defaults,
        merge,
        new_install_defaults,
    )

    reference = {"_docs": TABLE["reference_docs"], **effective_defaults(legacy=True)}
    result = {ROOT / "config.reference.json": json.dumps(reference, indent=2) + "\n"}
    for platform, filename in (
        ("diy", "config.minimal.json"),
        ("appliance", "config.minimal.appliance.json"),
    ):
        config = merge(
            new_install_defaults(platform),
            {
                "monero": {"wallet_address": TABLE["values"]["monero"]["wallet_address"]},
                "p2pool": {"stratum_password": TABLE["values"]["p2pool"]["stratum_password"]},
            },
        )
        result[ROOT / filename] = json.dumps(config, indent=2) + "\n"
    runtime = {key: TABLE[key] for key in ("values", "appliance", "materialize", "runtime")}
    runtime["LEGACY_ABSENT"] = [
        {key: value for key, value in entry.items() if key != "retired_by"}
        for entry in TABLE["LEGACY_ABSENT"]
    ]
    script = ROOT / "lib/pithead/19a-config-defaults.sh"
    before, rest = script.read_text().split("    cat <<'PITHEAD_DEFAULTS_JSON'\n", 1)
    _, after = rest.split("\nPITHEAD_DEFAULTS_JSON", 1)
    result[script] = (
        before
        + "    cat <<'PITHEAD_DEFAULTS_JSON'\n"
        + json.dumps(runtime, separators=(",", ":"))
        + "\nPITHEAD_DEFAULTS_JSON"
        + after
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    if args.check:
        from mining_dashboard.config.defaults import TABLE, default_of

        doc = (ROOT / "docs/configuration.md").read_text()
        for path in TABLE["materialize"]:
            values = [json.dumps(default_of(path, platform)) for platform in ("diy", "appliance")]
            values = [value.strip('"') for value in values]
            row = f"| `{path}` | `{values[0]}` | `{values[1]}` |"
            if row not in doc:
                stale.append(f"docs/configuration.md ({path})")
    for path, expected in artifacts().items():
        if args.check:
            if not path.exists() or path.read_text() != expected:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(expected)
    if stale:
        print("Stale defaults exports: " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
