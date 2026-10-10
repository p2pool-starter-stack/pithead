"""Preview-time guard for the fleet ``workers.api_port`` (#3358).

Mirrors pithead's ``validate_worker_endpoints`` (the host-side authority, which refuses the value
before it renders ``XMRIG_API_PORT``) so a bad port is refused at preview instead of reaching the
APPLY gate. Absent or null means the default, exactly as the host reads it.
"""

ERROR = "workers.api_port must be an integer between 1 and 65535 (the fleet default API port)."


def validate(proposed):
    """Return ``ERROR`` if a proposed ``workers.api_port`` is not an integer in 1-65535, else ''."""
    workers = proposed.get("workers") if isinstance(proposed, dict) else None
    if not isinstance(workers, dict) or workers.get("api_port") is None:
        return ""
    port = workers["api_port"]
    if isinstance(port, bool) or not isinstance(port, (int, float)):
        return ERROR
    if isinstance(port, float) and not port.is_integer():
        return ERROR
    return "" if 1 <= port <= 65535 else ERROR
