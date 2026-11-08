import io
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from mining_dashboard.collector import system


@pytest.fixture(autouse=True)
def reset_samples(monkeypatch):
    monkeypatch.setattr(system, "_resource_samples", {})
    monkeypatch.setattr(system, "_last_cpu_times", None)


def read_proc(text):
    return patch("builtins.open", side_effect=lambda *a, **k: io.StringIO(text))


def test_existing_reads_publish_raw_units_and_individual_times():
    with patch.object(system.time, "time", return_value=100):
        with patch.object(
            system.shutil, "disk_usage", return_value=SimpleNamespace(total=200, used=50)
        ):
            system.get_disk_usage()
        with read_proc("MemTotal: 1048576 kB\nMemAvailable: 524288 kB\n"):
            system.get_memory_usage()
        with patch.object(system.os, "getloadavg", return_value=(1.1, 2.2, 3.3)):
            system.get_load_average()
        with read_proc("HugePages_Total: 10\nHugePages_Free: 4\n"):
            system.get_hugepages_status()
    samples = system.get_host_resource_samples()
    assert samples["filesystem"] == {
        "sampled_at": 100,
        "reason": None,
        "value": {"total": 200, "used": 50},
    }
    assert samples["memory"]["value"] == {
        "total": 1024**3,
        "used": 512 * 1024**2,
        "available": 512 * 1024**2,
    }
    assert samples["load"]["value"] == [1.1, 2.2, 3.3]
    assert samples["hugepages"]["value"] == {"total": 10, "used": 6, "free": 4}
    with patch.object(system.time, "time", return_value=110):
        with patch.object(system.os, "getloadavg", return_value=(0, 0, 0)):
            system.get_load_average()
    assert system.get_host_resource_samples()["load"]["sampled_at"] == 110
    assert samples["load"]["sampled_at"] == 100


@pytest.mark.parametrize(
    "reader,name",
    [
        (system.get_memory_usage, "memory"),
        (system.get_hugepages_status, "hugepages"),
        (system.get_cpu_usage, "cpu"),
    ],
)
def test_proc_failure_has_no_resource_value(reader, name):
    with patch("builtins.open", side_effect=PermissionError):
        reader()
    assert system.get_host_resource_samples()[name]["value"] is None
    assert system.get_host_resource_samples()[name]["reason"] == "read_failed"


def test_failed_disk_read_replaces_previous_success():
    with patch.object(
        system.shutil, "disk_usage", return_value=SimpleNamespace(total=200, used=50)
    ):
        system.get_disk_usage()
    with patch.object(system.shutil, "disk_usage", side_effect=OSError):
        assert system.get_disk_usage()["percent"] == 0
    assert system.get_host_resource_samples()["filesystem"]["value"] is None


def test_load_read_failure():
    with patch.object(system.os, "getloadavg", side_effect=OSError):
        system.get_load_average()
    assert system.get_host_resource_samples()["load"]["reason"] == "read_failed"


@pytest.mark.parametrize(
    "text",
    [
        "MemTotal: 100 kB\n",
        "MemTotal: 0 kB\nMemAvailable: 0 kB\n",
        "MemTotal: 100 kB\nMemAvailable: 200 kB\n",
        "MemTotal: 100 MB\nMemAvailable: 20 MB\n",
    ],
)
def test_missing_or_invalid_memory_fields_are_unavailable(text):
    with read_proc(text):
        system.get_memory_usage()
    assert system.get_host_resource_samples()["memory"]["value"] is None


def test_cpu_needs_two_samples_excludes_guest_time_and_recovers_from_reset():
    with read_proc("cpu 0 0 0 100 0 0 0 0 0 0\n"):
        system.get_cpu_usage()
    assert system.get_host_resource_samples()["cpu"]["reason"] == "warming_up"
    with read_proc("cpu 100 0 100 300 0 0 0 0 50 0\n"):
        assert system.get_cpu_usage() == "50.0%"
    assert system.get_host_resource_samples()["cpu"]["value"] == 50
    with read_proc("cpu 0 0 0 10 0 0 0 0\n"):
        system.get_cpu_usage()
    assert system.get_host_resource_samples()["cpu"]["reason"] == "counter_reset"
    with read_proc("cpu 10 0 0 20 0 0 0 0\n"):
        system.get_cpu_usage()
    assert system.get_host_resource_samples()["cpu"]["value"] == 50


def test_cpu_failure_requires_new_baseline():
    with read_proc("cpu 0 0 0 100\n"):
        system.get_cpu_usage()
    with read_proc("not-cpu 1 2 3 4\n"):
        system.get_cpu_usage()
    with read_proc("cpu 20 0 0 200\n"):
        system.get_cpu_usage()
    assert system.get_host_resource_samples()["cpu"]["reason"] == "warming_up"


def test_partial_cpu_counter_rollback_is_unavailable_even_when_total_grows():
    with read_proc("cpu 100 0 0 100 0 0 0 0\n"):
        system.get_cpu_usage()
    with read_proc("cpu 90 0 100 200 0 0 0 0\n"):
        system.get_cpu_usage()
    assert system.get_host_resource_samples()["cpu"]["reason"] == "counter_reset"
    assert system.get_host_resource_samples()["cpu"]["value"] is None
