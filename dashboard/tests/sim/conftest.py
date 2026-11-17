import pytest


@pytest.fixture(autouse=True)
def xvb_enabled(monkeypatch):
    monkeypatch.setattr("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True)
