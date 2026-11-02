import dashboard_worker_detail_plugin as adapter
import pytest

from mining_dashboard import go_worker_detail

# ruff: noqa: S101


def test_install_replaces_all_worker_detail_aliases():
    from mining_dashboard.client import rig_config_meta
    from mining_dashboard.web import server
    from mining_dashboard.web.views import worker_detail

    assert server.build_worker_detail is go_worker_detail.build_worker_detail
    assert worker_detail.build_worker_detail is go_worker_detail.build_worker_detail
    assert worker_detail.config_drift is go_worker_detail.config_drift
    assert worker_detail._has_unsettled_apply is go_worker_detail._has_unsettled_apply
    assert (
        worker_detail.build_worker_hashrate_history
        is go_worker_detail.build_worker_hashrate_history
    )
    assert worker_detail.config_origin is go_worker_detail.config_origin
    assert rig_config_meta.config_origin is go_worker_detail.config_origin


def test_native_helper_failure_is_fatal_without_reference_fallback(monkeypatch):
    before = adapter.FALLBACKS.copy()

    def fail(*args, **kwargs):
        del args, kwargs
        raise RuntimeError("native worker detail unavailable")

    monkeypatch.setattr(go_worker_detail, "_run", fail)
    with pytest.raises(RuntimeError, match="native worker detail unavailable"):
        go_worker_detail.config_drift({"DONATION": 1}, {"DONATION": 2})
    assert adapter.FALLBACKS == before


@pytest.mark.parametrize(
    ("operation", "args"),
    [
        ("config_drift", [{}, {}, "false"]),
        ("config_origin", [{"source": "control"}, "yes", None, False]),
        ("build_worker_hashrate_history", [{}, [], "all", None]),
    ],
)
def test_native_operations_reject_invalid_contracts(operation, args):
    with pytest.raises(RuntimeError):
        go_worker_detail._run(operation, args)
