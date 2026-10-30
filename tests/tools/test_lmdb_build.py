import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("build_lmdb", ROOT / "scripts/tools/build-lmdb.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class BuildTests(unittest.TestCase):
    def test_checksum_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.tar.gz"
            archive.write_bytes(b"untrusted archive")
            output = Path(temporary) / "output"
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                builder.unpack(archive, output)
            self.assertFalse(output.exists())

    def test_symlink_source_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo(
                    f"monero-{builder.COMMIT}/external/db_drivers/liblmdb/mdb.c"
                )
                member.type = tarfile.SYMTYPE
                member.linkname = "../../outside"
                stream.addfile(member)
            with patch.object(builder, "ARCHIVE_SHA256", builder.digest(archive)):
                with self.assertRaisesRegex(ValueError, "Invalid source member"):
                    builder.unpack(archive, Path(temporary) / "output")

    def test_only_expected_files_extracted(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                for name in (*builder.FILES, "../../../outside"):
                    member = tarfile.TarInfo(
                        f"monero-{builder.COMMIT}/external/db_drivers/liblmdb/{name}"
                    )
                    member.size = 3
                    stream.addfile(member, io.BytesIO(b"abc"))
            output = Path(temporary) / "output"
            with patch.object(builder, "ARCHIVE_SHA256", builder.digest(archive)):
                builder.unpack(archive, output)
            self.assertEqual(set(builder.FILES), {p.name for p in output.iterdir()})
            self.assertFalse((Path(temporary) / "outside").exists())

    def test_wrong_target_rejected(self):
        with patch.object(builder.platform, "system", return_value="Darwin"):
            with self.assertRaisesRegex(ValueError, "Linux x86_64"):
                builder.build(Path("missing"), Path("unused"), "a" * 40)

    def test_incomplete_commit_rejected(self):
        with patch.object(builder.platform, "system", return_value="Linux"):
            with patch.object(builder.platform, "machine", return_value="x86_64"):
                with self.assertRaisesRegex(ValueError, "full Pithead source commit"):
                    builder.build(Path("missing"), Path("unused"), "abc123")

    def test_supported_monero_drift_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            with patch.object(builder.platform, "system", return_value="Linux"):
                with patch.object(builder.platform, "machine", return_value="x86_64"):
                    with patch.object(Path, "read_text", return_value="ARG MONERO_VERSION=other\n"):
                        with self.assertRaisesRegex(ValueError, "differs from supported Monero"):
                            builder.build(Path("missing"), output, "a" * 40)
            self.assertFalse(output.exists())

    def test_checksum_manifest_covers_all_payloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "mdb_copy").write_bytes(b"copier")
            (output / "provenance.json").write_text("{}")
            builder.write_checksums(output)
            self.assertEqual(
                (output / "SHA256SUMS").read_text(),
                f"{builder.digest(output / 'mdb_copy')}  mdb_copy\n"
                f"{builder.digest(output / 'provenance.json')}  provenance.json\n",
            )
            (output / "proof.json").write_text("{}")
            (output / "liblmdb").mkdir()
            (output / "liblmdb/mdb.c").write_text("source")
            builder.write_checksums(output)
            self.assertIn("  proof.json\n", (output / "SHA256SUMS").read_text())
            self.assertIn("  liblmdb/mdb.c\n", (output / "SHA256SUMS").read_text())
            self.assertNotIn("  SHA256SUMS", (output / "SHA256SUMS").read_text())


if __name__ == "__main__":
    unittest.main()
