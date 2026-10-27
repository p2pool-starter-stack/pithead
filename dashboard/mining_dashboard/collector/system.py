import os
import shutil
import time

from mining_dashboard.config.config import DISK_PATH

BYTES_IN_GB = 1024**3

_last_cpu_times = None
_avx2_supported = None
_resource_samples = {}


def get_cpu_avx2():
    """Whether the CPU advertises AVX2 (#104). RandomX runs far slower without it, so setup warns on
    it — surface the same persistent fact as a live badge. Reads /proc/cpuinfo (host CPU flags are
    visible inside the container); cached, since the flag is fixed for the life of the process.
    Returns True/False, or None when it can't be determined (non-Linux / unreadable)."""
    global _avx2_supported
    if _avx2_supported is not None:
        return _avx2_supported
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("flags"):
                    _avx2_supported = "avx2" in line.split()
                    return _avx2_supported
    except OSError:
        pass
    return None  # unknown — don't cache, and callers treat None as "can't judge" (no badge/alert)


def _record_resource(name, value, reason=None):
    _resource_samples[name] = {"sampled_at": time.time(), "value": value, "reason": reason}


def get_host_resource_samples():
    return _resource_samples.copy()


def get_disk_usage():
    try:
        usage = shutil.disk_usage(DISK_PATH)
        if usage.total <= 0 or not 0 <= usage.used <= usage.total:
            raise ValueError
        percent = (usage.used / usage.total) * 100
        _record_resource("filesystem", {"total": usage.total, "used": usage.used})
        return {
            "total_gb": usage.total / BYTES_IN_GB,
            "used_gb": usage.used / BYTES_IN_GB,
            "percent": percent,
            "percent_str": f"{percent:.1f}%",
        }
    except Exception:
        _record_resource("filesystem", None, "read_failed")
        return {"total_gb": 0, "used_gb": 0, "percent": 0, "percent_str": "0%"}


def get_memory_usage():
    try:
        mem_stats = {}
        with open("/proc/meminfo") as f:
            for line in f:
                key, _, rest = line.partition(":")
                if key in ("MemTotal", "MemAvailable"):
                    parts = rest.split()
                    if len(parts) != 2 or parts[1] != "kB":
                        raise ValueError
                    mem_stats[key] = int(parts[0]) * 1024
        mem_total = mem_stats["MemTotal"]
        mem_available = mem_stats["MemAvailable"]
        if mem_total <= 0 or not 0 <= mem_available <= mem_total:
            raise ValueError
        used = mem_total - mem_available
        percent = (used / mem_total) * 100
        _record_resource("memory", {"total": mem_total, "used": used, "available": mem_available})
        return {
            "available_gb": mem_available / BYTES_IN_GB,
            "total_gb": mem_total / BYTES_IN_GB,
            "used_gb": used / BYTES_IN_GB,
            "percent": percent,
            "percent_str": f"{percent:.1f}%",
        }
    except Exception:
        _record_resource("memory", None, "read_failed")
    return {"total_gb": 0, "used_gb": 0, "percent": 0, "percent_str": "0%"}


def get_load_average():
    try:
        load = os.getloadavg()
        _record_resource("load", list(load))
        return f"{load[0]:.2f} {load[1]:.2f} {load[2]:.2f}"
    except Exception:
        _record_resource("load", None, "read_failed")
        return "0.00 0.00 0.00"


def get_cpu_usage():
    global _last_cpu_times
    try:
        with open("/proc/stat") as f:
            parts = f.readline().split()
        if len(parts) < 5 or parts[0] != "cpu":
            raise ValueError
        values = [int(x) for x in parts[1:9]]
        if any(value < 0 for value in values):
            raise ValueError
        total = sum(values)
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        previous = _last_cpu_times
        _last_cpu_times = values
        if previous is None:
            _record_resource("cpu", None, "warming_up")
            return "0.0%"
        previous_idle = previous[3] + (previous[4] if len(previous) > 4 else 0)
        delta_total, delta_idle = total - sum(previous), idle - previous_idle
        if (
            len(values) != len(previous)
            or any(value < old for value, old in zip(values, previous, strict=False))
            or delta_total <= 0
            or not 0 <= delta_idle <= delta_total
        ):
            _record_resource("cpu", None, "counter_reset")
            return "0.0%"
        usage = ((delta_total - delta_idle) / delta_total) * 100
        _record_resource("cpu", usage)
        return f"{usage:.1f}%"
    except Exception:
        _last_cpu_times = None
        _record_resource("cpu", None, "read_failed")
        return "0.0%"


def get_hugepages_status():
    try:
        mem_stats = {}
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("HugePages_Total:"):
                    mem_stats["total"] = int(line.split()[1])
                elif line.startswith("HugePages_Free:"):
                    mem_stats["free"] = int(line.split()[1])
        hp_total, hp_free = mem_stats["total"], mem_stats["free"]
        if not 0 <= hp_free <= hp_total:
            raise ValueError
        hp_used = hp_total - hp_free
        _record_resource("hugepages", {"total": hp_total, "used": hp_used, "free": hp_free})
        val_str = f"{hp_used} / {hp_total}"
        if hp_total == 0:
            return "Disabled", "status-bad", val_str
        if hp_used > 0:
            return "Enabled", "status-ok", val_str
        return "Allocated", "status-ok", val_str
    except (OSError, ValueError, IndexError, KeyError):
        _record_resource("hugepages", None, "read_failed")
    return "Unknown", "status-warn", "0/0"
