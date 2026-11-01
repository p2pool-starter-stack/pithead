import math
import time

from mining_dashboard.config import config
from mining_dashboard.service import host_resources

FIELDS = {
    "build_workers": ("workers", "fleet"),
    "build_energy": ("energy", "fleet"),
    "build_host_resources": ("host_resources", "resources"),
}


def _resource_json(value):
    if isinstance(value, float) and not math.isfinite(value):
        return {"__pithead_nonfinite__": str(value)}
    if isinstance(value, dict):
        return {key: _resource_json(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_resource_json(item) for item in value]
    return value


def builders(captured, settings=None):
    settings = settings or {}
    result = {}
    for operation, (field, helper) in FIELDS.items():

        def capture(*args, operation=operation, field=field, helper=helper):
            values = list(args)
            if helper == "resources":
                values[1] = list(values[1])
                values = _resource_json(values)
            else:
                values[0] = list(values[0])
            if operation == "build_energy":
                endpoints = settings.get("worker_endpoints")
                if endpoints is None:
                    endpoints = [
                        {"name": entry["name"], "watts": entry.get("watts")}
                        for entry in config.current_worker_endpoints()
                    ]
                energy = (
                    settings["energy_config"]
                    if "energy_config" in settings
                    else config.DASHBOARD_ENERGY
                )
                values += [energy, endpoints]
            captured[field] = {
                "helper": helper,
                "operation": operation,
                "args": values,
                "now": settings["now"] if "now" in settings else time.time(),
                "max_age": (
                    settings["resource_max_age"]
                    if "resource_max_age" in settings
                    else host_resources._MAX_AGE
                ),
            }

        result[operation] = capture
    return result
