#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ENGINE_CONTRACT_SCRIPT="$ROOT/tests/os/engine-contract.py"
echo '== engine contract literal, loop and unresolved-wrapper controls =='
python3 - <<'PY'
import importlib.util
import json
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("engine", os.environ["ENGINE_CONTRACT_SCRIPT"])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
with tempfile.TemporaryDirectory() as directory:
    file = Path(directory) / "fixture.sh"
    file.write_text("docker inspect --format '{{.State.Running}}' tor\nfor status in running restarting paused; do\n ids=$(docker ps -q --filter status=\"$status\")\ndone\n")
    rows = engine.extract(directory)
    assert len(rows) == 4, rows
    assert any(row["args"] == ["ps", "-q", "--filter", "status=restarting"] for row in rows)
    file.write_text("unknown_wrapper() {\n docker ps \"$@\"\n}\n")
    try:
        engine.extract(directory)
    except ValueError as error:
        assert "unexpandable" in str(error)
    else:
        raise AssertionError("unexpandable wrapper passed")
    file.write_text("docker ps --filter status=\"$unknown\"\n")
    try:
        engine.extract(directory)
    except ValueError:
        pass
    else:
        raise AssertionError("unknown filter variable passed")
with tempfile.TemporaryDirectory() as directory:
    file = Path(directory) / "fixture.sh"
    file.write_text('docker ps --filter "label=com.docker.compose.project=$project" --format "{{.Names}}"\n')
    rows = engine.extract(directory)
    manifest = file.with_suffix(".json")
    manifest.write_text(json.dumps(rows))
    def run(argv, **kwargs):
        assert argv == ["docker", "ps", "--filter", "label=com.docker.compose.project=fixture-project", "--format", "{{.Names}}"], argv
        return SimpleNamespace(returncode=0, stdout="fixture-container\n")
    with patch.object(engine.subprocess, "run", side_effect=run):
        engine.run_manifest(manifest, "fixture-project", "fixture-compose", "fixture-container")
for value in ("running healthy", "exited none"):
    engine.check_shape(["inspect", "--format", "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"], value)
try:
    engine.check_shape(["inspect", "--format", "{{.State.Running}}"], "wrong")
except ValueError:
    pass
else:
    raise AssertionError("invalid inspect output passed")
print("engine contract selftest: PASS")
PY
