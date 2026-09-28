"""Keep all four CI uv installs authenticated and at the chosen version."""

import re
from pathlib import Path

workflow = Path(".github/workflows/ci.yml").read_text()
steps = re.findall(
    r"(?m)^      - uses: astral-sh/setup-uv@([0-9a-f]{40})[^\n]*\n"
    r"        with:\n"
    r"          version: \"([^\"]+)\"\n"
    r"          enable-cache: false$",
    workflow,
)
if len(steps) != 4 or len(set(steps)) != 1 or steps[0][1] != "0.12.13":
    raise SystemExit(
        "all four CI uv installs must use one full-SHA-pinned setup-uv action at 0.12.13"
    )
if "astral.sh/uv/" in workflow or "uv-install.sh" in workflow:
    raise SystemExit("CI must not execute an unchecked uv installer")
