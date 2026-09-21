"""First-boot setup page; the host owns validation, setup, and disk installs."""

import asyncio
import hmac
import json
import mimetypes
import os
import socket
import ssl
import stat
import sys
import tempfile

from aiohttp import web

from mining_dashboard.wizard.form import build_config
from mining_dashboard.wizard_config import (
    NEW_MACHINE_ANSWERS,
    prepare_config,
    validate_machine_name,
)
from mining_dashboard.wizard_install import validate_install_request
from mining_dashboard.wizard_node_probe import first_failure, probe_remote_nodes, saved_probe
from mining_dashboard.wizard_recovery import recovery_state, remember_changes, retry_handler

MAX_FAILURES = 5
EXIT_TOKEN_LOCKOUT = 3
RESTORE_MAX_BYTES = 64 * 1024 * 1024

COOKIE = "wizard_session"

_WEB_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "web")
_TRANSACTION_FILES = (
    "restore-archive",
    "restore-inflight",
    "install-attempt.json",
    "install-request",
    "submission-staging",
    "submission-active",
    "config.json",
    "rig-request.json",
)
_SUBMISSION_SIDECARS = ("auth-mode", "role")
_ROLLBACK_FILES = (*_TRANSACTION_FILES, *_SUBMISSION_SIDECARS, "last-attempt.json")
_PAGE_TEMP_FILES = (*_ROLLBACK_FILES, "restore-passphrase")


def _shell_html() -> str:
    with open(os.path.join(_WEB_DIR, "templates", "wizard.html")) as f:
        return f.read()


def _spool_remove(name: str, directory: str | None = None) -> None:
    try:
        os.unlink(os.path.join(directory or spool_dir(), name))
    except FileNotFoundError:
        pass


def _spool_exists(name: str) -> bool:
    return os.path.lexists(os.path.join(spool_dir(), name))


def _submission_conflict() -> web.Response | None:
    if any(
        _spool_exists(name) for name in ("restore-archive", "restore-inflight")
    ) or os.path.lexists(os.path.join(restore_dir(), "restore-archive")):
        return web.json_response(
            {"error": "another setup submission is already being processed"}, status=409
        )
    passphrase = os.path.lexists(os.path.join(restore_dir(), "restore-passphrase"))
    if passphrase and not _clear_failed_restore():
        return web.json_response(
            {"error": "an incomplete restore submission could not be cleared safely"}, status=500
        )
    if any(_spool_exists(name) for name in (*_TRANSACTION_FILES, "installing")):
        return web.json_response(
            {"error": "another setup submission is already being processed"}, status=409
        )
    return None


def _spool_clear_host_verdict() -> None:
    for name in ("error.txt", "node-probe.json"):
        _spool_remove(name)


def _spool_clear_submission_sidecars() -> None:
    for name in _SUBMISSION_SIDECARS:
        _spool_remove(name)


def _clear_failed_restore() -> bool:
    ok = True
    targets = [(name, restore_dir()) for name in ("restore-passphrase", "restore-archive")]
    targets.extend((name, None) for name in _ROLLBACK_FILES)
    for name, directory in targets:
        try:
            _spool_remove(name, directory)
        except OSError:
            ok = False
    return _clear_page_temps() and ok


def _clear_page_temps() -> bool:
    ok = True
    for directory in (spool_dir(), restore_dir()):
        try:
            entries = os.listdir(directory)
        except FileNotFoundError:
            continue
        except OSError:
            ok = False
            continue
        for entry in entries:
            if any(entry.startswith(f".{name}.") for name in _PAGE_TEMP_FILES):
                try:
                    mode = os.lstat(os.path.join(directory, entry)).st_mode
                    if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
                        ok = False
                        continue
                    _spool_remove(entry, directory)
                except FileNotFoundError:
                    pass
                except OSError:
                    ok = False
    return ok


def _canon_token(t: str) -> str:
    t = t.strip().upper()
    return t.removeprefix("PIT-")


def spool_dir() -> str:
    return os.environ.get("WIZARD_SPOOL", "/wizard-spool")


def restore_dir() -> str:
    return os.environ.get("WIZARD_RESTORE", "/wizard-restore")


def handoff_dir() -> str:
    return os.environ.get("WIZARD_HANDOFF", spool_dir())


def _spool_read(name: str, directory: str | None = None) -> str | None:
    path = os.path.join(directory or spool_dir(), name)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read().strip()


def _spool_json(name: str) -> dict:
    try:
        d = json.loads(_spool_read(name) or "{}")
    except ValueError:
        d = {}
    return d if isinstance(d, dict) else {}


def _reference() -> dict:
    return {k: v for k, v in _spool_json("config.reference.json").items() if not k.startswith("_")}


def _deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in (over or {}).items():
        out[k] = (
            _deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
        )
    return out


def strip_defaults(cfg: dict, ref: dict) -> dict:
    out: dict = {}
    for k, v in (cfg or {}).items():
        if k.startswith("_"):
            continue
        if isinstance(v, dict) and isinstance(ref.get(k), dict):
            sub = strip_defaults(v, ref[k])
            if sub:
                out[k] = sub
        elif k not in ref or v != ref[k]:
            out[k] = v
    return out


def _last_attempt() -> dict:
    return _spool_json("last-attempt.json")


def _rig_defaults() -> dict:
    return _spool_json("rig-defaults.json")


def _data_wiped() -> dict:
    return _spool_json("data-wiped.json")


def _saved_role() -> dict | None:
    saved = _spool_json("saved-role.json")
    return saved if isinstance(saved.get("role"), str) and saved["role"] else None


def wizard_stage() -> str:
    """Return the host-published step; the client never decides it."""
    if _spool_read("setup-failed") is not None or (
        installer_mode() and _spool_read("error.txt") is not None
    ):
        return "failed"
    if (
        _spool_read("handoff.json", handoff_dir()) is not None
        and _spool_read("handoff-ack") is None
    ):
        return "handoff"
    if _spool_read("installed") is not None or _spool_read("installing") is not None:
        return "installing"
    if _spool_read("applied") is not None or _spool_read("handoff-ack") is not None:
        return "installing" if installer_mode() and _spool_read("stick") != "1" else "done"
    if installer_mode():
        return "installer"
    return "setup"


def installer_mode() -> bool:
    return _spool_read("disks.tsv") is not None


def _disks() -> list[dict]:
    out = []
    for line in (_spool_read("disks.tsv") or "").splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        name, size, model, serial, state = parts[:5]
        out.append({"name": name, "size": size, "model": model, "serial": serial, "state": state})
    return out


def _authed(request: web.Request) -> bool:
    tok = os.environ.get("WIZARD_TOKEN", "")
    return bool(tok) and hmac.compare_digest(request.cookies.get(COOKIE, ""), tok)


async def index(request: web.Request) -> web.Response:
    return web.Response(text=_shell_html(), content_type="text/html")


async def auth(request: web.Request) -> web.Response:
    form = await request.post()
    tok = os.environ.get("WIZARD_TOKEN", "")
    supplied = str(form.get("token", "")).strip()
    if tok and hmac.compare_digest(_canon_token(supplied), _canon_token(tok)):
        resp = web.HTTPFound("/")
        resp.set_cookie(
            COOKIE,
            tok,
            httponly=True,
            secure=request.app["secure_cookie"],
            samesite="Strict",
        )
        raise resp
    request.app["failures"] += 1
    if request.app["failures"] >= MAX_FAILURES:
        resp = web.json_response(
            {
                "error": "Too many attempts — this machine printed a fresh token on its "
                "console; enter that one."
            },
            status=429,
        )
        await resp.prepare(request)
        await resp.write_eof()
        print("wizard: token failure limit reached — exiting for a re-mint", flush=True)
        request.app["exit"](EXIT_TOKEN_LOCKOUT)
        return resp
    return web.json_response({"error": "wrong token"}, status=403)


async def wizard_state(request: web.Request) -> web.Response:
    """Return the complete page state from host-published inputs."""
    if not _authed(request):
        return web.json_response({"error": "unauthenticated"}, status=401)
    ref = _reference()
    stage = wizard_stage()
    attempt, changes = prepare_config(_last_attempt(), ref)
    remembered, install_attempt, auth_mode = recovery_state(_spool_json, _spool_read, _disks())
    if changes:
        remember_changes(spool_dir(), changes, _spool_json, _spool_write_text)
    raw_handoff = _spool_read("handoff.json", handoff_dir()) if stage == "handoff" else None
    return web.json_response(
        {
            "stage": stage,
            "mode": "installer" if installer_mode() else "setup",
            "config": _deep_merge(ref, attempt or NEW_MACHINE_ANSWERS),
            "reference": ref,
            "error": _spool_read("error.txt"),
            "disks": _disks(),
            "rig_defaults": _rig_defaults(),
            "data_wiped": _data_wiped(),
            "handoff": json.loads(raw_handoff) if raw_handoff else None,
            "saved_role": _saved_role(),
            "node_probe": saved_probe(_spool_json),
            "config_changes": list(dict.fromkeys([*changes, *remembered])),
            "install_attempt": install_attempt,
            "auth_mode": auth_mode,
            "restore_enabled": request.app["restore_enabled"],
        }
    )


def _spool_write(name: str, data: str | bytes, directory: str | None = None) -> None:
    sd = directory or spool_dir()
    os.makedirs(sd, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=sd, prefix=f".{name}.")
    try:
        with os.fdopen(fd, "wb" if isinstance(data, bytes) else "w") as f:
            f.write(data)
        os.replace(tmp, os.path.join(sd, name))
    except OSError:
        try:
            os.close(fd)
        except OSError:
            pass
        _spool_remove(os.path.basename(tmp), sd)
        raise


def _spool_write_text(name: str, text: str, directory: str | None = None) -> None:
    _spool_write(name, text, directory)


def _spool_write_bytes(name: str, data: bytes, directory: str | None = None) -> None:
    _spool_write(name, data, directory)


def _spool_write_config(cfg: dict) -> None:
    _spool_write_text("config.json", json.dumps(cfg, indent=2))


def _publish_install_request(request: dict) -> None:
    _spool_write_text("install-attempt.json", json.dumps(request))
    _spool_write_text("install-request", f"{request['disk']}\t{request['wipe']}")


def _submit_rig(form: dict) -> web.Response:
    pool = str(form.get("rig_pool", "")).strip()
    host, _, port = pool.rpartition(":")
    if not host or not port.isdigit():
        return web.json_response(
            {"error": "enter the pool address as host:port — a Pithead answers on port 3333"},
            status=400,
        )
    stick = installer_mode() and str(form.get("disk", "")).strip() == "usb"
    install = None
    if installer_mode() and not stick:
        try:
            install = validate_install_request(form, _disks())
        except ValueError as exc:
            return web.json_response({"error": str(exc)}, status=400)
    rig = {"pool": pool}
    worker = str(form.get("rig_worker", "")).strip()
    if worker:
        rig["worker"] = worker
    password = str(form.get("rig_password", "")).strip()
    if password:
        rig["stratum_password"] = password
    _spool_clear_host_verdict()
    _spool_clear_submission_sidecars()
    _spool_write_text("submission-staging", "1")
    _spool_write_text("role", "rig")
    _spool_write_text("rig-request.json", json.dumps(rig))
    if install:
        _publish_install_request(install)
    _spool_write_text("submission-active", "1")
    return web.json_response({"status": "accepted"})


async def submit(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    async with request.app["submission_lock"]:
        conflict = _submission_conflict()
        if conflict is not None:
            return conflict
        try:
            return await _submit_locked(request)
        except OSError:
            cleaned = _clear_failed_restore()
            message = "could not stage the setup submission; submit it again"
            if not cleaned:
                message += "; temporary setup files could not be cleared safely"
            return web.json_response({"error": message}, status=500)


async def _submit_locked(request: web.Request) -> web.Response:
    form = await request.post()
    _spool_clear_host_verdict()
    _spool_write_text("stick", "1" if str(form.get("disk", "")).strip() == "usb" else "0")
    raw = str(form.get("config", "")).strip()
    ref = _reference()
    if (
        installer_mode()
        and str(form.get("wipe", "")).strip() == "keep"
        and str(form.get("disk", "")).strip()
    ):
        disk = str(form.get("disk", "")).strip()
        confirm = str(form.get("confirm", "")).strip()
        by_name = {d["name"]: d for d in _disks()}
        if disk not in by_name:
            return web.json_response({"error": "choose a disk from the list"}, status=400)
        if by_name[disk]["state"] == "pithead-with-data":
            if confirm != disk:
                return web.json_response({"error": f"type {disk} exactly to confirm"}, status=400)
            _spool_clear_host_verdict()
            _spool_clear_submission_sidecars()
            _spool_write_text("submission-staging", "1")
            _publish_install_request({"disk": disk, "wipe": "keep"})
            _spool_write_text("submission-active", "1")
            return web.json_response({"status": "accepted"})
    if str(form.get("role", "")).strip() == "rig":
        return _submit_rig(dict(form))
    try:
        cfg = json.loads(raw) if raw else build_config(dict(form))
        if not isinstance(cfg, dict):
            raise ValueError("the top level must be a JSON object")
    except (ValueError, TypeError) as exc:
        return web.json_response({"error": f"Not valid JSON: {exc}"}, status=400)
    try:
        cfg, changes = prepare_config(cfg, ref, reject_legacy_conflicts=True)
        validate_machine_name(cfg, _last_attempt())
    except ValueError as exc:
        return web.json_response({"error": f"Invalid configuration: {exc}"}, status=400)
    _spool_clear_submission_sidecars()
    mode = str(form.get("auth_mode", "")).strip()
    if mode in ("auto", "set", "none"):
        _spool_write_text("auth-mode", mode)
    install = None
    if installer_mode():
        try:
            install = validate_install_request(dict(form), _disks())
        except ValueError as exc:
            return web.json_response({"error": str(exc)}, status=400)
    report = await probe_remote_nodes(cfg)
    if report["configured"]:
        _spool_write_text("node-probe.json", json.dumps(report))
    if not report["ok"]:
        remember_changes(spool_dir(), changes, _spool_json, _spool_write_text)
        _spool_write_text("last-attempt.json", json.dumps(cfg))
        _spool_remove("install-request")
        return web.json_response({"error": first_failure(report), "node_probe": report}, status=400)
    _spool_write_text("submission-staging", "1")
    remember_changes(spool_dir(), changes, _spool_json, _spool_write_text)
    _spool_write_text("last-attempt.json", json.dumps(cfg))
    _spool_write_config(strip_defaults(cfg, ref) if ref else cfg)
    if install:
        _publish_install_request(install)
    _spool_write_text("submission-active", "1")
    return web.json_response({"status": "accepted", "config_changes": changes})


async def submit_restore(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    if not request.app["restore_enabled"]:
        return web.json_response(
            {"error": "restore upload requires HTTPS; reboot after setup TLS is available"},
            status=503,
        )
    async with request.app["submission_lock"]:
        return await _submit_restore_locked(request)


async def _submit_restore_locked(request: web.Request) -> web.Response:
    conflict = _submission_conflict()
    if conflict is not None:
        return conflict
    form = await request.post()
    _spool_clear_host_verdict()
    _spool_write_text("stick", "0")
    upload = form.get("archive")
    if not isinstance(upload, web.FileField):
        return web.json_response({"error": "choose a backup archive to upload"}, status=400)
    data = upload.file.read()
    if len(data) > RESTORE_MAX_BYTES:
        return web.json_response(
            {
                "error": f"archive too large (max {RESTORE_MAX_BYTES // (1024 * 1024)} MB) — "
                "a Pithead backup holds only config, keys and the dashboard database, "
                "never the blockchains"
            },
            status=400,
        )
    passphrase = str(form.get("passphrase", ""))
    if len(passphrase.encode()) > 4096:
        return web.json_response({"error": "restore passphrase is too large"}, status=400)
    install = None
    if installer_mode():
        try:
            install = validate_install_request(dict(form), _disks())
        except ValueError as exc:
            return web.json_response({"error": str(exc)}, status=400)
    try:
        _spool_clear_submission_sidecars()
        _spool_remove("last-attempt.json")
        _spool_write_text("submission-staging", "1")
        _spool_write_text("restore-passphrase", passphrase, restore_dir())
        if install:
            _publish_install_request(install)
        archive_dir = None if data.startswith(b"Salted__") else restore_dir()
        _spool_write_bytes("restore-archive", data, archive_dir)
        _spool_write_text("submission-active", "1")
    except OSError:
        cleaned = _clear_failed_restore()
        message = "could not stage the restore; submit it again"
        if not cleaned:
            message += "; temporary restore files could not be cleared safely"
        return web.json_response({"error": message}, status=500)
    return web.json_response({"status": "accepted"})


async def handoff(request: web.Request) -> web.Response:
    """Return the host-published credentials card over the authenticated page."""
    if not _authed(request):
        return web.json_response({"error": "unauthenticated"}, status=401)
    raw = _spool_read("handoff.json", handoff_dir())
    if not raw:
        return web.json_response({"error": "not ready"}, status=404)
    return web.json_response(json.loads(raw))


async def handoff_ack(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    if _spool_read("handoff.json", handoff_dir()) is None:
        return web.json_response({"error": "nothing to acknowledge"}, status=400)
    _spool_write_text("handoff-ack", "1")
    return web.json_response({"status": "provisioning"})


async def keep_role(request: web.Request) -> web.Response:
    if not _authed(request):
        raise web.HTTPFound("/")
    if _saved_role() is None:
        return web.json_response({"error": "nothing to keep"}, status=400)
    _spool_write_text("keep-role", "1")
    return web.json_response({"status": "kept"})


async def status(request: web.Request) -> web.Response:
    if installer_mode() and _spool_read("stick") != "1":
        if _spool_read("installed") is not None:
            return web.Response(
                text="Installed — the machine is switching itself off. "
                "Wait for it to go dark, then remove the USB stick and power it back on."
            )
        err = _spool_read("error.txt")
        if err is not None:
            return web.Response(text=f"Install failed: {err}")
        return web.Response(text="Copying the system to the disk…")
    if _spool_read("applied") is not None:
        if _spool_read("role") == "rig":
            return web.Response(
                text="Rig settings saved. The miner is starting on this machine now — "
                "it appears in your Pithead's Workers view once it connects."
            )
        return web.Response(text="Provisioned — the dashboard is coming up now.")
    err = _spool_read("error.txt")
    if err is not None:
        return web.Response(text=f"Rejected: {err} — go back and correct the form.")
    return web.Response(text="Waiting for this machine to validate and apply…")


def make_app(exit_fn=sys.exit, restore_enabled=False, secure_cookie=False) -> web.Application:
    if not _clear_page_temps():
        raise RuntimeError("temporary wizard files could not be cleared safely")
    mimetypes.add_type("text/javascript", ".mjs")
    mimetypes.add_type("text/javascript", ".js")
    app = web.Application(client_max_size=RESTORE_MAX_BYTES + 1_048_576)
    app["failures"] = 0
    app["exit"] = exit_fn
    app["restore_enabled"] = restore_enabled
    app["secure_cookie"] = secure_cookie
    app["submission_lock"] = asyncio.Lock()
    app.add_routes(
        [
            web.get("/", index),
            web.get("/setup", index),
            web.get("/install", index),
            web.post("/auth", auth),
            web.get("/api/wizard-state", wizard_state),
            web.post("/submit", submit),
            web.post("/submit-restore", submit_restore),
            web.get("/api/handoff", handoff),
            web.post("/handoff-ack", handoff_ack),
            web.post("/keep-role", keep_role),
            web.post("/retry", retry_handler(_authed, wizard_stage, spool_dir)),
            web.get("/status", status),
        ]
    )
    app.router.add_static("/static", os.path.join(_WEB_DIR, "static"))
    return app


def _host_only(hostport: str) -> str:
    if hostport.startswith("["):
        return hostport.partition("]")[0] + "]"
    return hostport.partition(":")[0]


def _socket_host(request: web.Request) -> str:
    sockname = None
    if request.transport is not None:
        sockname = request.transport.get_extra_info("sockname")
    if not isinstance(sockname, (tuple, list)) or not sockname:
        return "pithead.local"
    host = str(sockname[0])
    return f"[{host}]" if ":" in host else host


def _redirect_host(request: web.Request) -> str:
    """Honor only a Host header that this machine is known to answer on (#1118)."""
    claimed = _host_only(request.host or "")
    own = {_socket_host(request), "pithead.local", socket.gethostname(), socket.getfqdn()}
    known = {n.lower().rstrip(".") for n in own if n}
    if claimed.lower().rstrip(".") in known:
        return claimed
    return _socket_host(request)


async def _redirect_to_tls(request: web.Request) -> web.Response:
    raise web.HTTPMovedPermanently(f"https://{_redirect_host(request)}{request.rel_url}")


async def _serve(app: web.Application, bind: str, tls: ssl.SSLContext | None) -> web.AppRunner:
    host, _, port = bind.rpartition(":")
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, host or "0.0.0.0", int(port), ssl_context=tls).start()
    return runner


async def _run_both(bind: str, tls_bind: str, cert: str, key: str) -> None:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    redirect = web.Application()
    redirect.router.add_route("*", "/{tail:.*}", _redirect_to_tls)
    await _serve(make_app(restore_enabled=True, secure_cookie=True), tls_bind, ctx)
    await _serve(redirect, bind, None)
    await asyncio.Event().wait()


def main() -> None:
    if not os.environ.get("WIZARD_TOKEN"):
        print("wizard: WIZARD_TOKEN is required", file=sys.stderr)
        sys.exit(2)
    bind = os.environ.get("WIZARD_BIND", "0.0.0.0:8000")
    cert = os.environ.get("WIZARD_TLS_CERT", "")
    key = os.environ.get("WIZARD_TLS_KEY", "")
    if cert and key and os.path.exists(cert) and os.path.exists(key):
        tls_bind = os.environ.get("WIZARD_BIND_TLS", "0.0.0.0:8443")
        asyncio.run(_run_both(bind, tls_bind, cert, key))
        return
    host, _, port = bind.rpartition(":")
    web.run_app(make_app(), host=host or "0.0.0.0", port=int(port))


if __name__ == "__main__":
    main()
