import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S106, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, directory, implementation="python"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        PYTHONPATH=str(ROOT / "dashboard"),
        WIZARD_SPOOL=str(directory / "spool"),
        WIZARD_RESTORE=str(directory / "restore"),
        WIZARD_TOKEN="pit-fixture-token",
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=40,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.splitlines()[-1])


def _paired(tmp_path, script):
    expected = _run(script, tmp_path / "reference")
    actual = _run(script, tmp_path / "native", "go")
    assert actual == expected
    return actual


def test_rig_submit_http_and_ordered_spool_contract_match(tmp_path):
    result = _paired(
        tmp_path,
        r"""
import asyncio, json, os
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard import go_wizard_submission
    go_wizard_submission.install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
spool.mkdir(parents=True)
(spool / "error.txt").write_text("old")
def tree():
    return {p.name: p.read_bytes().hex() for p in sorted(spool.iterdir()) if p.is_file()}
async def run():
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token":"pit-fixture-token"}, allow_redirects=False)
        response = await client.post("/submit", data={
            "role":"rig", "rig_pool":"example.com:3333",
            "rig_worker":"shed-3", "rig_password":"fixture-stratum-pw",
        })
        return {"status": response.status, "body": (await response.read()).hex(), "spool": tree()}
print(json.dumps(asyncio.run(run()), separators=(",", ":")))
""",
    )
    assert result["status"] == 200
    assert result["spool"]["role"] == "726967"
    assert "config.json" not in result["spool"]
    assert "last-attempt.json" not in result["spool"]


@pytest.mark.parametrize("archive", [b"Salted__ciphertext", b"\x1f\x8bplaintext"])
def test_restore_archive_placement_and_passphrase_match(tmp_path, archive):
    result = _paired(
        tmp_path,
        r"""
import asyncio, json, os
from pathlib import Path
from aiohttp import FormData
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard import go_wizard_submission
    go_wizard_submission.install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
restore = Path(os.environ["WIZARD_RESTORE"])
spool.mkdir(parents=True); restore.mkdir(parents=True)
def tree(root):
    return {
        str(p.relative_to(root)): p.read_bytes().hex()
        for p in sorted(root.rglob("*"))
        if p.is_file()
    }
async def run():
    async with TestClient(
        TestServer(server.make_app(exit_fn=lambda code: None, restore_enabled=True))
    ) as client:
        await client.post("/auth", data={"token":"pit-fixture-token"}, allow_redirects=False)
        form = FormData()
        form.add_field(
            "archive", ARCHIVE, filename="backup.enc", content_type="application/octet-stream"
        )
        form.add_field("passphrase", "hunter2")
        response = await client.post("/submit-restore", data=form)
        return {"status": response.status, "body": (await response.read()).hex(),
                "spool": tree(spool), "restore": tree(restore)}
print(json.dumps(asyncio.run(run()), separators=(",", ":")))
""".replace("ARCHIVE", repr(archive)),
    )
    assert result["status"] == 200
    assert result["spool"]["submission-active"] == "31"
    assert result["restore"]["restore-passphrase"] == "68756e74657232"
