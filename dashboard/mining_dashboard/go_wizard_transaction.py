import json
import os
import subprocess

from aiohttp import web

from mining_dashboard import go_channel

REFERENCE_FUNCTIONS = {}
OPERATIONS = (
    "spool_write",
    "spool_remove",
    "spool_exists",
    "submission_conflict",
    "clear_submission_sidecars",
    "clear_failed_restore",
    "clear_page_temps",
)


def _payload(operation, **values):
    return {
        "operation": operation,
        "spool": os.environ.get("WIZARD_SPOOL", "/wizard-spool"),
        "restore": os.environ.get("WIZARD_RESTORE", "/wizard-restore"),
        **values,
    }


def _run(operation, data=None, **values):
    payload = _payload(operation, **values)
    if data is None:
        return go_channel.call("wizard", payload)
    payload["length"] = len(data)
    encoded = json.dumps(payload).encode() + b"\n"
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = "wizard-write"
    try:
        result = subprocess.run(  # noqa: S603
            [go_channel.binary()],
            input=encoded + data,
            capture_output=True,
            env=env,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OSError("native wizard writer unavailable") from error
    if result.returncode != 0:
        raise OSError("native wizard writer failed")
    try:
        return go_channel.response("wizard-write", result.stdout)
    except RuntimeError as error:
        raise OSError("native wizard writer returned invalid data") from error


def spool_write(name, data, directory=None) -> None:
    _run(
        "write",
        data=data if isinstance(data, bytes) else data.encode(),
        name=name,
        directory=directory or "",
    )


def spool_remove(name, directory=None) -> None:
    _run("remove", name=name, directory=directory or "")


def spool_exists(name) -> bool:
    return _run("exists", name=name)


def submission_conflict() -> web.Response | None:
    result = _run("conflict")
    if result is None:
        return None
    return web.json_response({"error": result["error"]}, status=result["status"])


def clear_submission_sidecars() -> None:
    _run("clear-sidecars")


def clear_failed_restore() -> bool:
    return _run("clear-restore")


def clear_page_temps() -> bool:
    return _run("clear-temps")


def install(server):
    from mining_dashboard import wizard_transaction

    for name in OPERATIONS:
        REFERENCE_FUNCTIONS.setdefault(name, getattr(wizard_transaction, name))
        native = globals()[name]
        setattr(wizard_transaction, name, native)
        if hasattr(server, name):
            setattr(server, name, native)
