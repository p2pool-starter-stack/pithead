import json

import pytest


def _write(tmp_path, workers):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"workers": {"api_port": 8081, "list": workers}}))
    return str(path)


def _env(host="10.0.0.5", port=8081, token=None):
    return json.dumps({"rig1": {"host": host, "port": port, "token": token or "probe-only"}})


def test_probe_token_joins_only_its_pinned_masked_endpoint(tmp_path):
    from mining_dashboard.config.config import load_worker_endpoints

    path = _write(
        tmp_path,
        [
            {"name": "rig1", "host": "10.0.0.5", "api_token": {"__secret__": True}},
            {"name": "rig2", "host": "10.0.0.6", "token": {"__secret__": True}},
        ],
    )
    assert load_worker_endpoints(path, tokens_env=_env()) == [
        {
            "name": "rig1",
            "host": "10.0.0.5",
            "api_token": {"__secret__": True},
            "read_token": "probe-only",
        },
        {"name": "rig2", "host": "10.0.0.6", "token": {"__secret__": True}},
    ]
    for env in (_env(host="10.0.0.7"), _env(port=9999), '{"rig1":"old-format"}'):
        assert "read_token" not in load_worker_endpoints(path, tokens_env=env)[0]


def test_probe_token_requires_explicit_sentinel_and_host(tmp_path):
    from mining_dashboard.config.config import load_worker_endpoints

    for worker in (
        {"name": "rig1", "host": "10.0.0.5"},
        {"name": "rig1", "api_token": {"__secret__": True}},
        {"name": "rig1", "host": "10.0.0.5", "token": {"__secret__": True}},
    ):
        path = _write(tmp_path, [worker])
        assert "read_token" not in load_worker_endpoints(path, tokens_env=_env())[0]


def test_invalid_probe_token_env_is_ignored(tmp_path):
    from mining_dashboard.config.config import load_worker_endpoints

    path = _write(
        tmp_path, [{"name": "rig1", "host": "10.0.0.5", "api_token": {"__secret__": True}}]
    )
    for env in ("not json", "[]", _env(token="has space"), _env(port=True)):
        assert "read_token" not in load_worker_endpoints(path, tokens_env=env)[0]


def test_current_worker_endpoints_uses_bound_probe_token(tmp_path, monkeypatch):
    import mining_dashboard.config.config as cfg

    path = _write(
        tmp_path, [{"name": "rig1", "host": "10.0.0.5", "api_token": {"__secret__": True}}]
    )
    monkeypatch.setattr(cfg, "HOST_CONFIG_PATH", path)
    monkeypatch.setattr(cfg, "DASHBOARD_WORKERS", None)
    monkeypatch.setenv("WORKER_API_TOKENS", _env())
    assert cfg.current_worker_endpoints() == [
        {
            "name": "rig1",
            "host": "10.0.0.5",
            "api_token": {"__secret__": True},
            "read_token": "probe-only",
        }
    ]


@pytest.mark.parametrize("fleet", [{}, {"api_port": None}, {"api_port": 8080}, {"api_port": 8081}])
@pytest.mark.parametrize("worker_port", [None, 8082])
@pytest.mark.parametrize("source", ["probe", "rigforge"])
def test_read_token_uses_effective_fleet_port(tmp_path, fleet, worker_port, source):
    from mining_dashboard.config.config import load_worker_endpoints

    worker = {
        "name": "rig1",
        "host": "worker.example",
        "api_token" if source == "probe" else "token": {"__secret__": True},
    }
    if worker_port is not None:
        worker["port"] = worker_port
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"workers": {**fleet, "list": [worker]}}))
    effective_port = worker_port or fleet.get("api_port") or 8080
    token = "a" * 64
    read_path = tmp_path / "read-tokens.json"
    for bound_port in (effective_port, effective_port + 1):
        bound = {"host": worker["host"], "port": bound_port}
        read_path.write_text(json.dumps([{**bound, "name": "rig1", "read_token": token}]))
        endpoints = load_worker_endpoints(
            str(path),
            read_tokens_path=str(read_path) if source == "rigforge" else None,
            tokens_env=json.dumps({"rig1": {**bound, "token": token}}) if source == "probe" else "",
        )
        assert len(endpoints) == 1
        if bound_port == effective_port:
            assert endpoints[0]["read_token"] == token
        else:
            assert "read_token" not in endpoints[0]
