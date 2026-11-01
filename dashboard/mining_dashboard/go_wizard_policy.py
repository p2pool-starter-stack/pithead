import os

from aiohttp import web

from mining_dashboard import go_channel
from mining_dashboard.config.defaults import default_of, new_install_defaults

REFERENCE_FUNCTIONS = {}
FORM_FIELDS = (
    "machine_name",
    "monero_wallet",
    "monero_mode",
    "pool",
    "stratum_password",
    "tari_mode",
    "tari_wallet",
    "monero_remote_host",
    "monero_remote_rpc",
    "monero_remote_zmq",
    "monero_remote_auth",
    "monero_remote_user",
    "monero_remote_pass",
    "tari_remote_host",
    "tari_remote_grpc",
    "prune",
    "healthchecks_url",
    "telegram_token",
    "telegram_chat",
    "role",
    "local_miner",
    "clearnet_sync",
    "timezone",
    "disk",
    "confirm",
    "wipe",
)
DEFAULT_PATHS = (
    "dashboard.host",
    "monero.mode",
    "p2pool.pool",
    "p2pool.stratum_password",
    "tari.mode",
    "monero.remote.rpc_port",
    "monero.remote.zmq_port",
    "tari.remote.grpc_port",
    "dashboard.timezone",
)
PORT_FIELDS = {"monero_remote_rpc", "monero_remote_zmq", "tari_remote_grpc"}


def _auth_call(operation, **values):
    return go_channel.call("wizard-auth", {"operation": operation, **values})


def _canon_token(token):
    return _auth_call("canon", token=token)


def _authed(request):
    from mining_dashboard.wizard import server

    return _auth_call(
        "cookie",
        token=os.environ.get("WIZARD_TOKEN", ""),
        cookie=request.cookies.get(server.COOKIE, ""),
    )


async def auth(request):
    from mining_dashboard.wizard import server

    form = await request.post()
    token = os.environ.get("WIZARD_TOKEN", "")
    result = _auth_call(
        "login",
        token=token,
        supplied=str(form.get("token", "")).strip(),
        failures=request.app["failures"],
        max_failures=server.MAX_FAILURES,
    )
    if result["accepted"]:
        response = web.HTTPFound("/")
        response.set_cookie(
            server.COOKIE,
            token,
            httponly=True,
            secure=request.app["secure_cookie"],
            samesite="Strict",
        )
        raise response
    request.app["failures"] = result["failures"]
    if result["status"] == 429:
        response = web.json_response(
            {
                "error": "Too many attempts — this machine printed a fresh token on its "
                "console; enter that one."
            },
            status=429,
        )
        await response.prepare(request)
        await response.write_eof()
        print("wizard: token failure limit reached — exiting for a re-mint", flush=True)
        request.app["exit"](server.EXIT_TOKEN_LOCKOUT)
        return response
    return web.json_response({"error": "wrong token"}, status=403)


def _fields(form, names=FORM_FIELDS):
    result = {}
    for name in names:
        value = form.get(name, "keep" if name == "wipe" else "")
        text = str(value).strip()
        field = {
            "text": text,
            "raw_string": value if isinstance(value, str) else None,
            "present": name in form,
            "truth": bool(value),
            "lower": str(value).lower(),
        }
        if name in PORT_FIELDS:
            field["digit"] = text.isdigit()
            if field["digit"]:
                try:
                    field["integer"] = int(text)
                except ValueError as error:
                    field["integer_error"] = str(error)
        result[name] = field
    return result


def build_config(form, *, tari_default=None, platform="appliance"):
    base = new_install_defaults(platform)
    plan = go_channel.call(
        "wizard-form",
        {
            "operation": "build",
            "defaults": {path: default_of(path, platform) for path in DEFAULT_PATHS},
            "fields": _fields(form),
            "tari_default": tari_default or "",
        },
    )
    for operation in plan:
        parent = base
        for name in operation["path"][:-1]:
            parent = parent[name]
        parent[operation["path"][-1]] = (
            dict(operation["pairs"]) if "pairs" in operation else operation["value"]
        )
    return base


def validate_install_request(form, disks):
    return go_channel.call(
        "wizard-form",
        {
            "operation": "install",
            "fields": _fields(form, ("disk", "confirm", "wipe")),
            "disks": disks,
        },
    )


def install(server):
    from mining_dashboard import wizard_install
    from mining_dashboard.wizard import form

    for name in ("_canon_token", "_authed", "auth", "build_config", "validate_install_request"):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(server, name))
        setattr(server, name, globals()[name])
    form.build_config = build_config
    wizard_install.validate_install_request = validate_install_request
