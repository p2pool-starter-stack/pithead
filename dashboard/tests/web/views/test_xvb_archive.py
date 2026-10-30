from pathlib import Path

import pytest

from tests.web.views import _xvb_views_support as support
from tests.web.views import test_xvb_views_xvb_calc as calc


def test_archive_parity_guard_runs_in_checkout():
    if not any((parent / "AI_RULES.md").is_file() for parent in Path(__file__).resolve().parents):
        pytest.skip("repository files are outside the dashboard image build context")

    assert support._XVB_ARCHIVE is not None
    assert support._XVB_ARCHIVE.is_file()
    guard = calc.TestXvbCalc.test_fallback_values_match_the_archived_source_files_player_rows
    assert not any(mark.name == "skipif" and mark.args[0] for mark in guard.pytestmark)


def test_archive_lookup_from_checkout_layout(tmp_path, monkeypatch):
    monkeypatch.setattr(
        support, "__file__", str(tmp_path / "dashboard/tests/web/views/_xvb_views_support.py")
    )

    assert support._xvb_archive() == (
        tmp_path
        / "docs/research/xvb-delivery-study/data/sources/xmrvsbeast-reward_estimate_pub.txt"
    )


def test_archive_lookup_tolerates_shallow_image_layout(monkeypatch):
    monkeypatch.setattr(support, "__file__", "/app/tests/_xvb_views_support.py")

    assert support._xvb_archive() is None
