import io
import json
import time
import tracemalloc
from types import SimpleNamespace
from unittest.mock import patch

from mining_dashboard.collector import system
from mining_dashboard.service.host_resources import build_host_resources


def test_bounded_collection_and_outlook_cost(monkeypatch):
    monkeypatch.setattr(system, "_resource_samples", {})
    monkeypatch.setattr(system, "_last_cpu_times", None)
    meminfo = (
        "MemTotal: 1048576 kB\nMemAvailable: 524288 kB\nHugePages_Total: 10\nHugePages_Free: 4\n"
    )
    ticks = 0

    def proc_file(filename, *args, **kwargs):
        nonlocal ticks
        if filename == "/proc/stat":
            ticks += 100
            return io.StringIO(f"cpu {ticks} 0 0 {ticks} 0 0 0 0\n")
        assert filename == "/proc/meminfo"
        return io.StringIO(meminfo)

    now = time.time()
    rows = [
        {"ts": now - (168 - i) * 3600, "disk_used_gb": 100 + i / 10, "disk_total_gb": 500}
        for i in range(169)
    ]
    with (
        patch("builtins.open", side_effect=proc_file) as proc_reads,
        patch.object(
            system.shutil,
            "disk_usage",
            return_value=SimpleNamespace(total=500 * 1024**3, used=117 * 1024**3),
        ) as disk_reads,
        patch.object(system.os, "getloadavg", return_value=(1, 1, 1)) as load_reads,
    ):
        system.get_cpu_usage()
        tracemalloc.start()
        started = time.perf_counter()
        for _ in range(1000):
            system.get_disk_usage()
            system.get_memory_usage()
            system.get_hugepages_status()
            system.get_load_average()
            system.get_cpu_usage()
            metadata = system.get_host_resource_samples()
            result = build_host_resources(metadata, rows)
            assert result["cpu"]["state"] == "available"
            assert result["capacity_outlook"]["state"] == "estimated"
        elapsed = time.perf_counter() - started
        _, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
    assert proc_reads.call_count == 3001
    assert disk_reads.call_count == load_reads.call_count == 1000
    assert len(rows) == 169
    print(
        f"HOST_RESOURCE_COST cycles=1000 elapsed_ms={elapsed * 1000:.3f} peak_bytes={peak} "
        f"snapshot_metadata_bytes={len(json.dumps(metadata))} "
        f"api_section_bytes={len(json.dumps(result))} additional_resource_reads=0 "
        "additional_history_rows=0"
    )
