import json


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
