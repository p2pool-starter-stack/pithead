from pathlib import Path

import pytest

from mining_dashboard.service.logs import redaction

VECTORS = Path(__file__).resolve().parents[4] / "tests/data/log-redaction-vectors.tsv"


def _vectors():
    rows = [line.split("\t") for line in VECTORS.read_text().splitlines() if line]
    assert len(rows) >= 10
    return rows


@pytest.mark.parametrize(("name", "raw", "expected"), _vectors())
def test_shared_vector(name, raw, expected):
    assert redaction.redact_line(raw) == expected


def test_a_pattern_file_with_a_non_substitution_line_is_refused(tmp_path):
    bad = tmp_path / "bad.sed"
    bad.write_text("s/a/b/g\ny/abc/xyz/\n")
    with pytest.raises(ValueError, match="bad.sed:2"):
        redaction.load_rules(bad)


def test_the_bash_slice_is_generated_from_the_same_pattern_file():
    root = Path(__file__).resolve().parents[4]
    slice_text = (root / "lib/pithead/07a-redact-patterns.sh").read_text()
    assert redaction.PATTERN_FILE.read_text().rstrip("\n") in slice_text


def test_whitespace_is_ascii_only_like_sed_posix_space():
    line = "--merge-mine tari://172.28.0.27:18142\u00a0" + "T" * 60 + " --local-api"
    assert redaction.redact_line(line) == line
