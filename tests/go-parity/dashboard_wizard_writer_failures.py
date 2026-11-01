import json
import subprocess
import sys

import pytest
from tests.web._wizard_support import *  # noqa: F403

from mining_dashboard import go_wizard_transaction

# ruff: noqa: F405, S101, S106, S603


@pytest.mark.parametrize("failure", ["timeout", "nonzero", "malformed"])
async def test_writer_process_failure_rolls_back_restore_secrets(
    client, spool, restore_spool, monkeypatch, tmp_path, failure
):
    wrapper = tmp_path / "writer_failure.py"
    wrapper.write_text(
        """import os, sys, time
from pathlib import Path
target = Path(os.environ["WIZARD_SPOOL"]) / ".restore-archive.interrupted"
target.touch(mode=0o600)
target.write_bytes(b"interrupted-wallet-archive")
if os.environ["PITHEAD_TEST_WRITER_FAILURE"] == "timeout":
    time.sleep(5)
if os.environ["PITHEAD_TEST_WRITER_FAILURE"] == "malformed":
    print("not-json")
    sys.exit(0)
sys.exit(17)
"""
    )
    monkeypatch.setenv("PITHEAD_TEST_WRITER_FAILURE", failure)
    real_run = subprocess.run

    def fail_archive_write(command, *args, **kwargs):
        env = kwargs.get("env") or {}
        if env.get("PITHEAD_DASHBOARD_HELPER") != "wizard-write":
            return real_run(command, *args, **kwargs)
        raw = kwargs.get("input", b"")
        separator = "\n" if isinstance(raw, str) else b"\n"
        header = json.loads(raw.partition(separator)[0]) if raw else {}
        if header.get("name") != "restore-archive":
            return real_run(command, *args, **kwargs)
        kwargs["timeout"] = 0.5
        return real_run([sys.executable, str(wrapper)], *args, **kwargs)

    monkeypatch.setattr(go_wizard_transaction.subprocess, "run", fail_archive_write)
    await _auth(client)
    response = await client.post(
        "/submit-restore",
        data=_archive_form(
            data=b"Salted__encrypted-wallet-archive",
            passphrase="restore-passphrase-fixture",
        ),
    )
    body = await response.text()

    assert response.status == 500
    assert "could not stage the restore" in body
    assert "restore-passphrase-fixture" not in body
    assert "encrypted-wallet-archive" not in body
    assert sorted(path.name for path in spool.iterdir()) == ["stick"]
    assert not list(restore_spool.iterdir())
