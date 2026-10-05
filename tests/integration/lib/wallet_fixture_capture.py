"""Capture the prepared wallet cache; also streamed before the fixture CLI source."""

import os
import subprocess
import tempfile
from pathlib import Path


def capture_fixture(fixture, baseline):
    fingerprint = fixture.identity(baseline)
    if fingerprint is None:
        return
    item = fixture.wallet_container({baseline})
    if item is None:
        raise ValueError("configured wallet container is missing")
    if fixture.identity_values(item["Config"]["Env"]) != fingerprint:
        raise ValueError("source container wallet identity differs from the baseline")
    fixture.local_volume()
    directory = Path(
        tempfile.mkdtemp(
            prefix="pithead-wallet-fixture-",
            dir=os.environ.get("IT_SCRATCH_DIR") or "/var/tmp",  # noqa: S108 -- mkdtemp creates an owner-only directory under the persistent sticky temp root.
        )
    )
    was_running = item["State"]["Running"]
    try:
        stopped = fixture.stop_wallet(item)
        if stopped["State"]["ExitCode"] != 0 or stopped["State"].get("OOMKilled"):
            raise ValueError("source wallet has no graceful save proof")
        archive = directory / "wallet.tar"
        with archive.open("xb") as stream:
            command = f"test ! -e {fixture.WALLET_DIR}/.payout-scanning && tar -C {fixture.WALLET_DIR} -cf - payout-wallet payout-wallet.keys"
            fixture.docker(
                *fixture.helper(item["Image"], True, directory, "capture"), command, stdout=stream
            )
            stream.flush()
            os.fsync(stream.fileno())
        contents = fixture.manifest(archive)
        # Uninstall also removes owned images. Keep the exact tar-capable image offline.
        with (directory / "image.tar").open("xb") as stream:
            fixture.docker("image", "save", item["Image"], stdout=stream)
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
        if was_running:
            fixture.docker("start", item["Id"], stdout=subprocess.DEVNULL)
    print(directory)
