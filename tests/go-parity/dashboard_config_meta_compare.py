import os

import dashboard_config_meta_plugin as adapter
import pytest

from mining_dashboard.client import rig_config_meta, xmrig_client
from mining_dashboard.service.workers import worker_change_audit

# ruff: noqa: S101

pytest_plugins = ["dashboard_config_meta_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

GOOD = {
    "revision": "a1b2c3d4e5f60718",
    "changed_at": "2026-08-23T14:30:45Z",
    "source": "control",
    "last_change_id": "0f1e2d3c4b5a6978",
}


def _reference(meta):
    with adapter.python_operation():
        return rig_config_meta.parse_config_meta(meta)


@pytest.mark.parametrize(
    "meta",
    [
        GOOD,
        {"revision": "aaaabbbbccccdddd", "changed_at": None, "source": None},
        {},
        {"revision": None, "source": None},
        {**GOOD, "source": "operator"},
        {**GOOD, "revision": "x" * 65},
        {**GOOD, "last_change_id": "y" * 4096},
        {**GOOD, "revision": "rev/../.."},
        {**GOOD, "changed_at": "2026-08-23 14:30:45"},
        {**GOOD, "revision": {"opaque": object()}},
    ],
)
def test_native_parser_matches_reference(meta):
    expected = _reference(meta)
    actual = rig_config_meta.parse_config_meta(meta)
    assert actual == expected
    if actual is not None:
        assert actual is not meta
        for name, value in actual.items():
            if value is not None:
                assert value is meta[name]


def test_all_production_aliases_use_native_parser():
    assert rig_config_meta.parse_config_meta is adapter.NATIVES["parse_config_meta"]
    assert xmrig_client.parse_config_meta is adapter.NATIVES["parse_config_meta"]
    assert worker_change_audit.parse_config_meta is adapter.NATIVES["parse_config_meta"]


def test_unicode_category_newer_than_python_is_rejected():
    digit = "\U0001e4f0"
    stamp = f"{digit * 4}-{digit * 2}-{digit * 2}T{digit * 2}:{digit * 2}:{digit * 2}Z"
    meta = {**GOOD, "changed_at": stamp}
    assert _reference(meta)["changed_at"] is None
    assert rig_config_meta.parse_config_meta(meta)["changed_at"] is None


def test_python_unicode_14_digits_and_trailing_newlines_are_accepted():
    digit = "\U0001e950"
    stamp = f"{digit * 4}-{digit * 2}-{digit * 2}T{digit * 2}:{digit * 2}:{digit * 2}Z\n"
    meta = {**GOOD, "revision": "token\n", "changed_at": stamp}
    expected = _reference(meta)
    actual = rig_config_meta.parse_config_meta(meta)
    assert actual == expected
    assert actual["revision"] is meta["revision"]
    assert actual["changed_at"] is meta["changed_at"]


def test_repeated_equal_metadata_preserves_each_input_identity():
    from mining_dashboard import go_config_meta

    first = {**GOOD, "revision": "".join(["equal", "_token"])}
    second = {**GOOD, "revision": "".join(["equal_", "token"])}
    assert first["revision"] == second["revision"]
    assert first["revision"] is not second["revision"]
    go_config_meta._native_plan.cache_clear()
    before = adapter.CALLS["config_meta_policy"]
    one = rig_config_meta.parse_config_meta(first)
    two = rig_config_meta.parse_config_meta(second)
    assert one["revision"] is first["revision"]
    assert two["revision"] is second["revision"]
    assert adapter.CALLS["config_meta_policy"] == before + 1
