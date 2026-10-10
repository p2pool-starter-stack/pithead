"""#3358: the dashboard-side preview guard for the fleet ``workers.api_port``, mirroring the host
check in pithead's ``validate_worker_endpoints``."""

import pytest

from mining_dashboard.service.workers import fleet_api_port


@pytest.mark.parametrize("port", [1, 8080, 65535, 8080.0])
def test_in_range_accepted(port):
    assert fleet_api_port.validate({"workers": {"api_port": port}}) == ""


@pytest.mark.parametrize("proposed", [{}, {"workers": {}}, {"workers": {"api_port": None}}, "x"])
def test_absent_means_default(proposed):
    assert fleet_api_port.validate(proposed) == ""


@pytest.mark.parametrize(
    "port",
    [0, 65536, -1, True, False, 80.5, "8080", "", [], {}, float("inf"), float("nan")],
)
def test_invalid_refused(port):
    err = fleet_api_port.validate({"workers": {"api_port": port}})
    assert "workers.api_port must be an integer between 1 and 65535" in err
