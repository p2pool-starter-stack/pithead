import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUIDE = HERE.parents[1] / "docs/dev/manual-qa/sample-configs.md"


class ChecklistCasesTests(unittest.TestCase):
    def generate(self, document):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            source = root / "guide.md"
            source.write_text(document)
            result = subprocess.run(  # noqa: S603
                [
                    sys.executable,
                    str(HERE / "checklist-cases.py"),
                    str(source),
                    str(root),
                    "m" * 95,
                    "t" * 100,
                    "s" * 95,
                    "0" * 64,
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            return result, sorted(p.name for p in root.glob("broken-*.message"))

    def test_optional_cell_whitespace(self):
        document = GUIDE.read_text()
        before, section = document.split("## Broken configs", 1)
        for indent, cell_space in (("", " "), ("", ""), ("  ", "\t")):
            with self.subTest(indent=indent, cell_space=cell_space):
                lines = [
                    indent
                    + "|"
                    + "|".join(
                        cell_space + cell.strip() + cell_space for cell in line.split("|")[1:-1]
                    )
                    + "|"
                    if line.startswith("|")
                    else line
                    for line in section.splitlines()
                ]
                result, messages = self.generate(before + "## Broken configs" + "\n".join(lines))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(messages), 17)

    def test_added_row_without_matching_mutation_is_rejected(self):
        document = GUIDE.read_text()
        last = next(
            line
            for line in reversed(document.split("## Broken configs", 1)[1].splitlines())
            if line.startswith("|")
        )
        for prefix in ("|", "| ", "  |\t"):
            with self.subTest(prefix=prefix):
                extra = prefix + 'Set `monero.mode` to `"invalid-extra"` | `monero.mode must be` |'
                result, messages = self.generate(document.replace(last, last + "\n" + extra))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("checklist mutations changed", result.stderr)
                self.assertEqual(messages, [])


if __name__ == "__main__":
    unittest.main()
