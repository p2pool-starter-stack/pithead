# ruff: noqa: S101, S603, S607
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

import dashboard_http_plugin
import pytest
from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer

ROOT = Path(__file__).resolve().parents[2]
GO_ROOT = ROOT / "go"
CLI_BINARY = GO_ROOT / "bin" / "pithead"
DASHBOARD_BINARY = GO_ROOT / "bin" / "dashboard"
PARSER_SUITE = ROOT / "tests" / "stack" / "lib" / "config-document-parser.py"
DEPTH_COMPAT_BYTES = 2411


def _go_environment():
    cache = ROOT / ".go-cache"
    paths = {
        "GOCACHE": cache / "build",
        "GOMODCACHE": cache / "mod",
        "GOPATH": cache / "gopath",
        "TMPDIR": cache / "tmp",
    }
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({key: str(value.resolve()) for key, value in paths.items()})
    env["GOPROXY"] = "off"
    return env


def _copy_and_build(command, source, replacement):
    scratch_root = ROOT / ".go-cache" / "tmp"
    scratch_root.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="native-ownership-", dir=scratch_root))
    module = scratch / "go"
    shutil.copytree(GO_ROOT, module, ignore=shutil.ignore_patterns("bin"))
    target = module / source
    original = target.read_text()
    if original.count(replacement[0]) != 1:
        shutil.rmtree(scratch)
        raise AssertionError(f"mutation seam changed: {source}")
    target.write_text(original.replace(*replacement))
    binary = scratch / command
    result = subprocess.run(
        ["go", "build", "-trimpath", "-o", str(binary), f"./cmd/{command}"],
        cwd=module,
        env=_go_environment(),
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    if result.returncode:
        shutil.rmtree(scratch)
        raise AssertionError(result.stderr[-4000:])
    return scratch, binary


def _cli_wrapper(directory, binary):
    trace = directory / "native.tsv"
    wrapper = directory / "pithead-helper"
    wrapper.write_text(
        "#!/bin/sh\n"
        '"$NATIVE_BINARY" "$@"\n'
        "native_status=$?\n"
        "native_size=-1\n"
        'if [ "${PITHEAD_GO_HELPER:-}" = config-document ] && [ -f "${1:-}" ]; then\n'
        '    native_size=$(wc -c <"$1" | tr -d " ")\n'
        "fi\n"
        "native_reason=native-result\n"
        'if [ "$native_status" -eq 125 ]; then\n'
        "    native_reason=unsupported\n"
        f'    [ "$native_size" -ne {DEPTH_COMPAT_BYTES} ] || native_reason=depth-limit\n'
        "fi\n"
        'printf "%s\\t%s\\t%s\\n" "$native_status" "$native_size" "$native_reason" '
        '>>"$NATIVE_TRACE"\n'
        'exit "$native_status"\n'
    )
    wrapper.chmod(0o755)
    return wrapper, trace, binary


def _run_parser_suite(implementation, binary=CLI_BINARY):
    with tempfile.TemporaryDirectory() as raw_directory:
        directory = Path(raw_directory)
        wrapper, trace, native = _cli_wrapper(directory, binary)
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env["PITHEAD_IMPL"] = implementation
        if implementation == "go":
            env.update(
                PITHEAD_GO_BINARY=str(wrapper),
                NATIVE_BINARY=str(native),
                NATIVE_TRACE=str(trace),
            )
        result = subprocess.run(
            [sys.executable, str(PARSER_SUITE)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        entries = []
        if trace.exists():
            for line in trace.read_text().splitlines():
                status, size, reason = line.split("\t")
                entries.append((int(status), int(size), reason))
        return result, entries


def _assert_parser_native(entries):
    compatibility = [
        entry for entry in entries if entry == (125, DEPTH_COMPAT_BYTES, "depth-limit")
    ]
    unexpected = [
        entry
        for entry in entries
        if entry[0] not in (0, 1) and entry != (125, DEPTH_COMPAT_BYTES, "depth-limit")
    ]
    assert compatibility == [(125, DEPTH_COMPAT_BYTES, "depth-limit")]
    assert not unexpected, f"unexpected native fallback statuses: {unexpected}"
    assert Counter(entry[0] for entry in entries) == {0: 5, 1: 97, 125: 1}


def test_config_document_unchanged_oracle_requires_native_ownership():
    baseline, baseline_entries = _run_parser_suite("bash")
    selected, selected_entries = _run_parser_suite("go")
    assert baseline.returncode == 0, baseline.stdout + baseline.stderr
    assert selected.returncode == 0, selected.stdout + selected.stderr
    assert baseline_entries == []
    _assert_parser_native(selected_entries)


def test_config_document_mutation_control_catches_hidden_fallback():
    scratch, binary = _copy_and_build(
        "pithead",
        Path("internal/config/document.go"),
        (
            "\treturn &Document{root: root}, nil\n",
            "\treturn &Document{root: root}, ErrUnsupportedDocument\n",
        ),
    )
    try:
        result, entries = _run_parser_suite("go", binary)
        assert result.returncode == 0, result.stdout + result.stderr
        with pytest.raises(AssertionError, match="unexpected native fallback"):
            _assert_parser_native(entries)
    finally:
        shutil.rmtree(scratch)


def _miner_body():
    return json.dumps(
        {
            "fingerprint": "fixture-fingerprint",
            "local_only": False,
            "password": "fixture-password",
            "password_set": True,
            "tls": True,
            "url": "stratum+ssl://192.0.2.5:3333",
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()


async def _run_miner_route(binary, inputs_available=True):
    body = _miner_body()
    trace = []
    app = web.Application()

    async def ready(_request):
        return web.Response(text="ready")

    async def inputs(_request):
        trace.append("inputs")
        if not inputs_available:
            raise web.HTTPNotFound()
        return web.json_response(
            {
                "ok": True,
                "input": {
                    "HostIP": "192.0.2.5",
                    "Bind": "0.0.0.0",
                    "Port": 3333,
                    "Password": "fixture-password",
                    "TLS": "true",
                    "Fingerprint": "fixture-fingerprint",
                },
            }
        )

    async def reference(_request):
        reason = "inputs-unavailable" if not inputs_available else "native-route-bypassed"
        trace.append(f"reference:{reason}")
        return web.Response(
            body=body,
            headers={
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
            },
        )

    app.router.add_get("/", ready)
    app.router.add_get("/_go/miner-connection", inputs)
    app.router.add_get("/api/miner-connection", reference)
    server = TestServer(app)
    await server.start_server()
    previous = dashboard_http_plugin.BINARY
    dashboard_http_plugin.BINARY = binary
    process = dashboard_http_plugin.DashboardProcess(str(server.make_url("/")), False)
    try:
        await process.start()
        async with ClientSession() as session:
            async with session.get(f"{process.url}/api/miner-connection") as response:
                contract = (
                    response.status,
                    await response.read(),
                    response.headers.get("Content-Type"),
                    response.headers.get("Cache-Control"),
                )
                if contract[0] == 200 and trace == ["inputs"]:
                    trace.append("native:success")
    finally:
        await process.close()
        dashboard_http_plugin.BINARY = previous
        await server.close()
    return contract, trace


def _assert_miner_native(trace):
    assert trace == ["inputs", "native:success"], f"unexpected reference fallback: {trace}"


@pytest.mark.asyncio
async def test_miner_connection_requires_native_ownership_and_lists_compatibility():
    contract, trace = await _run_miner_route(DASHBOARD_BINARY)
    assert contract == (200, _miner_body(), "application/json; charset=utf-8", "no-store")
    _assert_miner_native(trace)

    fallback_contract, fallback_trace = await _run_miner_route(
        DASHBOARD_BINARY, inputs_available=False
    )
    assert fallback_contract == contract
    assert fallback_trace == ["inputs", "reference:inputs-unavailable"]


@pytest.mark.asyncio
async def test_miner_connection_mutation_control_catches_hidden_fallback():
    scratch, binary = _copy_and_build(
        "dashboard",
        Path("internal/dashboard/web/data.go"),
        (
            'case "miner-connection":\n\t\tvar input api.MinerConnectionInput\n',
            'case "miner-connection":\n\t\th.dataFallback(w, r)\n\t\treturn\n\t\tvar input api.MinerConnectionInput\n',
        ),
    )
    try:
        contract, trace = await _run_miner_route(binary)
        assert contract == (200, _miner_body(), "application/json; charset=utf-8", "no-store")
        with pytest.raises(AssertionError, match="unexpected reference fallback"):
            _assert_miner_native(trace)
    finally:
        shutil.rmtree(scratch)
