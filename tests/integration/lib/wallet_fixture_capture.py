"""Capture the prepared wallet cache; also streamed before the fixture CLI source."""

import os
import subprocess
import tempfile
from pathlib import Path


def capture_fixture(fixture, baseline, diagnostics=True):
    fingerprint = fixture.identity(baseline)
    if fingerprint is None:
        return
    item = fixture.wallet_container({baseline}, timeout=30)
    if item is None:
        raise ValueError("configured wallet container is missing")
    if fixture.identity_values(item["Config"]["Env"]) != fingerprint:
        raise ValueError("source container wallet identity differs from the baseline")
    fixture.local_volume(timeout=30)
    directory = Path(
        tempfile.mkdtemp(
            prefix="pithead-wallet-fixture-",
            dir=os.environ.get("IT_SCRATCH_DIR") or "/var/tmp",  # noqa: S108 -- mkdtemp creates an owner-only directory under the persistent sticky temp root.
        )
    )
    was_running = item["State"]["Running"]
    restart_allowed = True
    try:
        stopped = fixture.stop_wallet(item, diagnostics=diagnostics, timeout=30)
        if stopped["State"]["ExitCode"] != 0 or stopped["State"].get("OOMKilled"):
            raise ValueError("source wallet has no graceful save proof")
        archive = directory / "wallet.tar"
        with archive.open("xb") as stream:
            command = f"test ! -e {fixture.WALLET_DIR}/.payout-scanning && tar -C {fixture.WALLET_DIR} -cf - payout-wallet payout-wallet.keys"
            restart_allowed = False
            try:
                fixture.docker(
                    *fixture.helper(item["Image"], True, directory, "capture"),
                    command,
                    stdout=stream,
                    timeout=180,
                )
            finally:
                fixture.cleanup_helper(f"{directory.name}-capture")
                restart_allowed = True
            stream.flush()
            os.fsync(stream.fileno())
        contents = fixture.manifest(archive)
        # Uninstall also removes owned images. Keep the exact tar-capable image offline.
        with (directory / "image.tar").open("xb") as stream:
            fixture.docker("image", "save", item["Image"], stdout=stream, timeout=180)
            stream.flush()
            os.fsync(stream.fileno())
        fixture.write_state(
            directory,
            {
                "baseline": str(baseline),
                "directory": str(directory),
                "identity": fingerprint,
                "image": item["Image"],
                "archive_sha256": fixture.digest(archive),
                "image_sha256": fixture.digest(directory / "image.tar"),
                "contents": contents,
                "stage": "captured",
            },
        )
        fixture.sync_directory(directory.parent)
    except Exception:
        # No branch was deployed; remove only this capture's known private files.
        for name in ("wallet.tar", "image.tar", "state.tmp", "state.json"):
            path = directory / name
            if path.exists() or path.is_symlink():
                fixture.private(path.lstat())
                path.unlink()
        directory.rmdir()
        fixture.sync_directory(directory.parent)
        raise
    finally:
        if was_running and restart_allowed:
            fixture.docker("start", item["Id"], stdout=subprocess.DEVNULL, timeout=180)
    print(directory)
