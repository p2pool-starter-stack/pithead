#!/usr/bin/env bash
# Execute the shipped helper with deterministic pathname substitutions.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== sync-gate marker scope, permissions and descriptor races =="
python3 - "$HERE/../../../lib/pithead/40a-sync-gate-reset.sh" <<'PY'
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

code = Path(sys.argv[1]).read_text().split("<<'PYMARKER'\n", 1)[1].split("\nPYMARKER", 1)[0]


class MarkerTest(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.fixture.cleanup)
        self.directory = Path(self.fixture.name)
        self.marker = self.directory / "sync-gate-reset"

    def run_helper(self, scope="2"):
        with patch.object(sys, "argv", ["marker", str(self.directory), scope]):
            exec(compile(code, "sync-gate-marker", "exec"), {})

    def test_absent_and_typed_marker_keep_tari_scope(self):
        self.run_helper()
        self.assertEqual(self.marker.read_bytes(), b"tari-only\n")
        self.run_helper()
        self.assertEqual(self.marker.read_bytes(), b"tari-only\n")

    def test_privileged_writer_marker_is_readable_by_dashboard(self):
        # The descriptor sets other-read regardless of the writer UID or umask.
        previous_umask = os.umask(0o077)
        try:
            self.run_helper()
        finally:
            os.umask(previous_umask)
        self.assertEqual(self.marker.stat().st_mode & 0o777, 0o644)

    def test_pending_full_reset_wins(self):
        self.marker.touch()
        self.run_helper()
        self.assertEqual(self.marker.read_bytes(), b"")

    def test_full_reset_overrides_tari(self):
        self.run_helper()
        self.run_helper("1")
        self.assertEqual(self.marker.read_bytes(), b"")

    def test_nonregular_pending_entries_are_full_or_fail_closed(self):
        target = self.directory / "target"
        target.write_text("unchanged")
        for kind in ("symlink", "dangling", "fifo", "directory"):
            with self.subTest(kind=kind):
                if kind == "directory":
                    self.marker.mkdir()
                    with self.assertRaises(OSError):
                        self.run_helper()
                    self.marker.rmdir()
                    continue
                if kind == "fifo":
                    os.mkfifo(self.marker)
                else:
                    self.marker.symlink_to(target if kind == "symlink" else self.directory / "absent")
                self.run_helper()
                self.assertEqual(self.marker.read_bytes(), b"")
                self.marker.unlink()
        self.assertEqual(target.read_text(), "unchanged")

    def test_write_path_swap_cannot_redirect_descriptor(self):
        target = self.directory / "target"
        target.write_text("unchanged")
        real_open = os.open

        def substitute(name, *args, **kwargs):
            descriptor = real_open(name, *args, **kwargs)
            if str(name).startswith(".sync-gate-reset."):
                os.unlink(name, dir_fd=kwargs["dir_fd"])
                os.symlink(target, name, dir_fd=kwargs["dir_fd"])
            return descriptor

        with patch.object(os, "open", side_effect=substitute):
            with self.assertRaises(OSError):
                self.run_helper()
        self.assertEqual(target.read_text(), "unchanged")

    def test_read_path_swap_cannot_follow_symlink_or_block_on_fifo(self):
        real_open = os.open
        for kind in ("symlink", "fifo"):
            self.marker.write_bytes(b"tari-only\n")

            def substitute(name, *args, **kwargs):
                if name == "sync-gate-reset":
                    self.marker.unlink()
                    if kind == "fifo":
                        os.mkfifo(self.marker)
                    else:
                        target = self.directory / "target"
                        target.write_bytes(b"tari-only\n")
                        self.marker.symlink_to(target)
                return real_open(name, *args, **kwargs)

            with patch.object(os, "open", side_effect=substitute):
                self.run_helper()
            self.assertEqual(self.marker.read_bytes(), b"")
            self.marker.unlink()


unittest.main(argv=["marker"], verbosity=2)
PY
