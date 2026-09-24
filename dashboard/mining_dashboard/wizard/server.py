"""First-boot setup wizard (#77 phase 3) — the server half.

A deliberately tiny aiohttp app the host runs pre-provisioning via
``pithead firstboot-wizard``: token gate -> the wizard SPA -> an atomically written candidate
config in the spool. The HOST does everything privileged (validation, ``pithead setup``,
disk installs) — this server only asks, the same trust shape as the #33 control channel.

The frontend is the dashboard's stack (``web/templates/wizard.html`` +
``web/static/wizard/wizard.mjs`` — preact/htm, shared CSS, shared pure logic), so the first page
anyone sees matches the dashboard they live in afterwards. This module serves the shell, the
static assets, and a small state API; it renders no HTML of its own.

Env contract (set by ``pithead firstboot-wizard``):
  WIZARD_TOKEN     one-time token printed on the console (case/prefix-insensitive to enter)
  WIZARD_SPOOL     rw spool dir (default /wizard-spool)
  WIZARD_RESTORE   rw volatile dir (default /wizard-restore) for the restore passphrase and an
                   unencrypted restore archive; host-side it is root-owned tmpfs, where the host
                   also keeps an installer's config candidate, so none reaches the persistent spool
  WIZARD_HANDOFF   dir the host publishes the credentials card in (default: WIZARD_SPOOL); the
                   installer points it at WIZARD_RESTORE so the card never persists either
  TMPDIR           set to WIZARD_RESTORE, so aiohttp's multipart spill of an upload stays volatile
  WIZARD_BIND      plain bind host:port (default 0.0.0.0:8000)
  WIZARD_BIND_TLS  TLS bind (default 0.0.0.0:8443), used when WIZARD_TLS_CERT/KEY exist; restore
                   uploads and the Secure session cookie are enabled only on that TLS site

After ``MAX_FAILURES`` bad tokens the process exits 3; the host re-mints a fresh token and
restarts the container — the re-mint loop lives host-side on purpose.
"""

import asyncio
import hmac
import json
import mimetypes
import os
import ssl
import sys

from aiohttp import web

from mining_dashboard.wizard.form import build_config
from mining_dashboard.wizard_config import (
    NEW_MACHINE_ANSWERS,
    deep_merge,
    prepare_config,
    strip_defaults,
    validate_machine_name,
)
from mining_dashboard.wizard_install import validate_install_request
from mining_dashboard.wizard_node_probe import first_failure, probe_remote_nodes, saved_probe
from mining_dashboard.wizard_recovery import recovery_state, remember_changes, retry_handler
from mining_dashboard.wizard_redirect import redirect_to_tls
from mining_dashboard.wizard_transaction import (
    clear_failed_restore,
    clear_page_temps,
    clear_submission_sidecars,
    restore_dir,
    spool_dir,
    spool_remove,
    spool_write,
    submission_conflict,
)

MAX_FAILURES = 5
EXIT_TOKEN_LOCKOUT = 3
# Restore-at-setup upload cap (#909): a Pithead backup holds only config, keys and the
# dashboard database, never the blockchains — 64 MiB is generous headroom over that. Mirrored
# in the pithead script's own RESTORE_MAX_BYTES (client + server, per the spool contract); the
# two can't share a literal across languages, so keep the VALUE in step by hand.
RESTORE_MAX_BYTES = 64 * 1024 * 1024

COOKIE = "wizard_session"

_WEB_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "web")


def _shell_html() -> str:
    """The static shell, read per request through a sync helper (ruff's async rules, and the
    file can change under a live container only in development)."""
    with open(os.path.join(_WEB_DIR, "templates", "wizard.html")) as f:
        return f.read()


def _spool_clear_host_verdict() -> None:
    for name in ("error.txt", "node-probe.json"):
        spool_remove(name)


def _canon_token(t: str) -> str:
    """The operator is transcribing from a console, often on a phone that autocapitalizes.
    Case and the pit- prefix carry no entropy — the six-character suffix does — so neither
    should be able to fail a correct transcription."""
    t = t.strip().upper()
    return t.removeprefix("PIT-")


def handoff_dir() -> str:
    return os.environ.get("WIZARD_HANDOFF", spool_dir())


def _spool_read(name: str, directory: str | None = None) -> str | None:
    """Blocking on purpose: single-operator page, tiny local files."""
    path = os.path.join(directory or spool_dir(), name)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read().strip()


def _spool_json(name: str) -> dict:
    """A spool file parsed as a dict; absent, unparseable, or non-dict all mean {}. Every
    spool reader fails open the same way — a broken file blocks nothing."""
    try:
        d = json.loads(_spool_read(name) or "{}")
    except ValueError:
        d = {}
    return d if isinstance(d, dict) else {}


def _reference() -> dict:
    """Every key with its documented default, published into the spool by the host."""
    return {k: v for k, v in _spool_json("config.reference.json").items() if not k.startswith("_")}


def _last_attempt() -> dict:
    return _spool_json("last-attempt.json")


def _rig_defaults() -> dict:
    """The rig role's pre-fill, published by the HOST like the disk inventory: a Pithead pool
    discovered on the LAN (when one answered) and this machine's own name for the worker
    field."""
    return _spool_json("rig-defaults.json")


def _data_wiped() -> dict:
    """The data-wipe note (#1121), published by the HOST the same way as the rig pre-fill: when
    /data was reinitialized before this boot, {when, reason, recovery} — recovery distinguishes
    a deliberate factory-reset (nothing to warn about) from the wedged-partition case, where the
    operator's right next move is restoring a backup rather than treating this like a fresh
    machine. {} when there is nothing to report."""
    return _spool_json("data-wiped.json")


def _saved_role() -> dict | None:
    """The role this machine is already set up as, published by the HOST only on a set-up-again
    boot (#1318): {"role": "rig", "pool", "worker"} for a rig, {"role": "pithead"} or
    {"role": "both"} for a coordinator. Its PRESENCE is the signal to offer "Keep it", so a file
    that names no role reads as ABSENT rather than as an error — the one thing this screen must
    never do is offer to keep a role it cannot name. None means "run the normal wizard"."""
    saved = _spool_json("saved-role.json")
    return saved if isinstance(saved.get("role"), str) and saved["role"] else None


def wizard_stage() -> str:
    """Which step this machine is actually on, decided by the SPOOL — never by the client.

    A page refresh must not walk back into an editable form after a config was accepted, and the
    client cannot know that alone: a bench session refreshed mid-provision got the setup form back.

    failed     the host ended an installer attempt with an error
    handoff    credentials published (in handoff_dir()), waiting for the operator to save them
    installing the ack released a disk install, which is copying or done
    done       provisioning under way (or finished) — nothing left to edit
    installer  running from the installation medium
    setup      no config accepted yet
    """
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
    """The host sets this when it booted from removable media and a target disk exists.
    The container never probes hardware — it renders what the host put in the spool."""
    return _spool_read("disks.tsv") is not None


def _disks() -> list[dict]:
    """The host's inventory, as data. Parsing stays server-side so the client renders objects,
    never splits strings — and a model containing markup is just a JSON string to it."""
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
    """The shell. It carries no data — the client fetches /api/wizard-state after the gate.
    Also answers /setup and /install so a bookmarked step keeps working."""
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
        # Flush the refusal to the browser BEFORE the host restarts the container for a
        # re-mint. prepare/write_eof are idempotent, so aiohttp's own finish step (which
        # runs them again once this handler returns) is a no-op — this just moves the bytes
        # onto the wire ahead of the exit, instead of the process tearing down mid-request.
        await resp.prepare(request)
        await resp.write_eof()
        print("wizard: token failure limit reached — exiting for a re-mint", flush=True)
        request.app["exit"](EXIT_TOKEN_LOCKOUT)
        return resp
    return web.json_response({"error": "wrong token"}, status=403)


async def wizard_state(request: web.Request) -> web.Response:
    """Everything the SPA needs to render: which flow, the effective config (the defaults with a
    previous configuration merged over them — a pre-seed, a reinstall pre-fill or a rejected
    submission, each of which WINS WHOLE; a machine that has never been configured gets this
    page's own default instead), the reference, the host's error, and the disk inventory."""
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
            # Kept for the field's original meaning; `stage` is what the client renders from.
            "mode": "installer" if installer_mode() else "setup",
            "config": deep_merge(ref, attempt or NEW_MACHINE_ANSWERS),
            "reference": ref,
            "error": _spool_read("error.txt"),
            "disks": _disks(),
            "rig_defaults": _rig_defaults(),
            "data_wiped": _data_wiped(),
            "handoff": json.loads(raw_handoff) if raw_handoff else None,
            # Always present, null when this is not a set-up-again boot (#1318).
            "saved_role": _saved_role(),
            # Always present, null when no probe ran at all (#1889).
            "node_probe": saved_probe(_spool_json),
            "config_changes": list(dict.fromkeys([*changes, *remembered])),
            "install_attempt": install_attempt,
            "auth_mode": auth_mode,
            "restore_enabled": request.app["restore_enabled"],
        }
    )


def _spool_write_text(name: str, text: str, directory: str | None = None) -> None:
    spool_write(name, text, directory)


def _spool_write_bytes(name: str, data: bytes, directory: str | None = None) -> None:
    spool_write(name, data, directory)


def _spool_write_config(cfg: dict) -> None:
    _spool_write_text("config.json", json.dumps(cfg, indent=2))


def _publish_install_request(request: dict) -> None:
    """Publish the host's trigger last, after every input it consumes is complete."""
    _spool_write_text("install-attempt.json", json.dumps(request))
    _spool_write_text("install-request", f"{request['disk']}\t{request['wipe']}")


def _submit_rig(form: dict) -> web.Response:
    """The RigForge role's submission: no pithead config at all — a pool address, a worker name,
    an optional stratum password, on their own spool channel. The coordinator flow stays
    byte-for-byte untouched because nothing goes near config.json; the HOST dials the pool. On the
    medium the disk gates match every other role, bar one target: "usb" runs from the stick."""
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
    clear_submission_sidecars()
    _spool_write_text("submission-staging", "1")
    # The role rides beside the request so /status can narrate honestly after it is consumed.
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
        conflict = submission_conflict()
        if conflict is not None:
            return conflict
        try:
            return await _submit_locked(request)
        except OSError:
            cleaned = clear_failed_restore()
            message = "could not stage the setup submission; submit it again"
            if not cleaned:
                message += "; temporary setup files could not be cleared safely"
            return web.json_response({"error": message}, status=500)


async def _submit_locked(request: web.Request) -> web.Response:
    form = await request.post()
    _spool_clear_host_verdict()
    # Restated per SUBMISSION (#1835): a stale stick choice must not mute the install narration.
    _spool_write_text("stick", "1" if str(form.get("disk", "")).strip() == "usb" else "0")
    raw = str(form.get("config", "")).strip()
    ref = _reference()
    # Keep-everything reinstall: the preserved config wins, so the submission carries NO config
    # and nothing here may write one — a config candidate would provision over the survivor,
    # and a handoff card would show credentials the machine will never serve. Disk gates only.
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
            # The disk really holds an install: keep means KEEP — no config crosses, no
            # password is generated, no card appears, whatever a crafted submit carried.
            if confirm != disk:
                return web.json_response({"error": f"type {disk} exactly to confirm"}, status=400)
            _spool_clear_host_verdict()
            clear_submission_sidecars()
            _spool_write_text("submission-staging", "1")
            _publish_install_request({"disk": disk, "wipe": "keep"})
            _spool_write_text("submission-active", "1")
            return web.json_response({"status": "accepted"})
        # A blank disk with wipe=keep (the client's default) is just a fresh install — fall
        # through unconditionally. The no-JS path submits individual form FIELDS, not a config
        # blob, so "no config present" cannot distinguish a bare keep from a form submit; the
        # host's validation names what is missing either way.
    # The rig role, AFTER the keep gate on purpose: keep means KEEP in every role — a rig
    # submission against a preserved install must not smuggle a role change past the survivor.
    if str(form.get("role", "")).strip() == "rig":
        return _submit_rig(dict(form))
    # The JSON pane IS the configuration — what the operator can see is exactly what gets
    # applied. build_config remains the fallback for a client with no JavaScript.
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
    clear_submission_sidecars()
    # The dashboard-login choice travels BESIDE the config: "no login" is an empty password,
    # which is also what "not chosen yet" looks like, so the config alone cannot express intent.
    # The host reads this to decide whether to generate one.
    mode = str(form.get("auth_mode", "")).strip()
    if mode in ("auto", "set", "none"):
        _spool_write_text("auth-mode", mode)
    # On the installation medium, config and disk arrive TOGETHER — one page, one submission,
    # validated without side effects; the trigger is published only after the candidate.
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
        spool_remove("install-request")
        return web.json_response({"error": first_failure(report), "node_probe": report}, status=400)
    # Keep the full attempt for a retry, write only what differs from the defaults.
    _spool_write_text("submission-staging", "1")
    remember_changes(spool_dir(), changes, _spool_json, _spool_write_text)
    _spool_write_text("last-attempt.json", json.dumps(cfg))
    _spool_write_config(strip_defaults(cfg, ref) if ref else cfg)
    if install:
        _publish_install_request(install)
    _spool_write_text("submission-active", "1")
    return web.json_response({"status": "accepted", "config_changes": changes})


async def submit_restore(request: web.Request) -> web.Response:
    """Restore-at-setup (#909, #786 sub-issue B): an uploaded encrypted backup archive + its
    emergency-kit passphrase, in place of the config form. This server only asks, and the HOST
    decrypts, validates and extracts (firstboot_consume_restore). The passphrase — and an archive
    that is not encrypted — go only to the volatile restore dir, never the persistent spool; the
    host consumes them once and deletes them either way. TLS only: over plain HTTP the passphrase
    would cross the LAN in clear."""
    if not _authed(request):
        raise web.HTTPFound("/")
    # aiohttp enforces client_max_size (set in make_app) itself, answering 413 before this
    # body even finishes reading — no try/except needed to turn that into a response.
    if not request.app["restore_enabled"]:
        return web.json_response(
            {"error": "restore upload requires HTTPS; reboot after setup TLS is available"},
            status=503,
        )
    async with request.app["submission_lock"]:
        return await _submit_restore_locked(request)


async def _submit_restore_locked(request: web.Request) -> web.Response:
    conflict = submission_conflict()
    if conflict is not None:
        return conflict
    form = await request.post()
    _spool_clear_host_verdict()
    # Restated like /submit (#1835): a restore installs to a DISK — the gate below refuses "usb".
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
    # On the installation medium, disk + wipe ride beside the archive — the SAME gate a typed
    # submission takes, so a restore can install too. Validation writes no trigger.
    install = None
    if installer_mode():
        try:
            install = validate_install_request(dict(form), _disks())
        except ValueError as exc:
            return web.json_response({"error": str(exc)}, status=400)
    try:
        clear_submission_sidecars()
        spool_remove("last-attempt.json")
        _spool_write_text("submission-staging", "1")
        _spool_write_text("restore-passphrase", passphrase, restore_dir())
        if install:
            _publish_install_request(install)
        archive_dir = None if data.startswith(b"Salted__") else restore_dir()
        _spool_write_bytes("restore-archive", data, archive_dir)
        _spool_write_text("submission-active", "1")
    except OSError:
        cleaned = clear_failed_restore()
        message = "could not stage the restore; submit it again"
        if not cleaned:
            message += "; temporary restore files could not be cleared safely"
        return web.json_response({"error": message}, status=500)
    return web.json_response({"status": "accepted"})


async def handoff(request: web.Request) -> web.Response:
    """The credentials card, once the host publishes it: dashboard login, dashboard URL, and the
    stratum address. Authed, over the same TLS the operator typed secrets into — a 32-character
    random password transcribed from a console was never realistic. Read from handoff_dir(),
    which the installer keeps volatile."""
    if not _authed(request):
        return web.json_response({"error": "unauthenticated"}, status=401)
    raw = _spool_read("handoff.json", handoff_dir())
    if not raw:
        return web.json_response({"error": "not ready"}, status=404)
    return web.json_response(json.loads(raw))


async def handoff_ack(request: web.Request) -> web.Response:
    """The operator confirms the credentials are saved; provisioning proceeds. The page goes
    dark from here — the host removes this container and starts the stack."""
    if not _authed(request):
        raise web.HTTPFound("/")
    if _spool_read("handoff.json", handoff_dir()) is None:
        return web.json_response({"error": "nothing to acknowledge"}, status=400)
    _spool_write_text("handoff-ack", "1")
    return web.json_response({"status": "provisioning"})


async def keep_role(request: web.Request) -> web.Response:
    """The "Keep it" half of the set-up-again screen: the operator wants the machine left as it
    is, so there is nothing to configure and nothing to submit. The host is waiting on this file
    to carry on booting with the configuration it already has."""
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
            # A rig serves no dashboard, so this page is the last thing it will ever show:
            # say where the machine went rather than promising a link that does not exist.
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
    if not clear_page_temps():
        raise RuntimeError("temporary wizard files could not be cleared safely")
    # Some minimal hosts lack /etc/mime.types, so ES modules would be served as
    # application/octet-stream, which browsers refuse to execute. Same fix as the dashboard's
    # server.py — the wizard serves the same static tree.
    mimetypes.add_type("text/javascript", ".mjs")
    mimetypes.add_type("text/javascript", ".js")
    # aiohttp's default (1 MiB) refuses a restore upload before submit_restore's own, clearer
    # cap gets a chance to run; a little slack over RESTORE_MAX_BYTES covers multipart overhead.
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
    redirect.router.add_route("*", "/{tail:.*}", redirect_to_tls)
    await _serve(make_app(restore_enabled=True, secure_cookie=True), tls_bind, ctx)
    await _serve(redirect, bind, None)
    # Both sites serve until the host stops the container; nothing ever sets this event.
    await asyncio.Event().wait()


def main() -> None:
    if not os.environ.get("WIZARD_TOKEN"):
        print("wizard: WIZARD_TOKEN is required", file=sys.stderr)
        sys.exit(2)
    bind = os.environ.get("WIZARD_BIND", "0.0.0.0:8000")
    cert = os.environ.get("WIZARD_TLS_CERT", "")
    key = os.environ.get("WIZARD_TLS_KEY", "")
    # TLS because this page carries real secrets — node passwords, a Telegram bot token, a
    # view key if one is pasted into the config. A self-signed certificate warns the browser,
    # which is the honest tradeoff: the alternative is those secrets in clear on the LAN. The
    # console prints the fingerprint so the warning can actually be checked.
    if cert and key and os.path.exists(cert) and os.path.exists(key):
        tls_bind = os.environ.get("WIZARD_BIND_TLS", "0.0.0.0:8443")
        asyncio.run(_run_both(bind, tls_bind, cert, key))
        return
    host, _, port = bind.rpartition(":")
    web.run_app(make_app(), host=host or "0.0.0.0", port=int(port))


if __name__ == "__main__":
    main()
