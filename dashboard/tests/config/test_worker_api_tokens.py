import json

# #2349: the masked config mount can only ever hold a set workers.list[].token as the
# {"__secret__": true} sentinel (#440). The real value rides WORKER_API_TOKENS instead — a JSON
# {name: token} map rendered by render_env, the same owner-only .env path XMRIG_API_TOKEN already
# takes — and is merged back onto the masked entry, restoring the "forces token-auth for that one
# rig" promise (docs/configuration.md) the masked mount alone cannot keep.


def _write(tmp_path, payload):
    p = tmp_path / "config.json"
    p.write_text(json.dumps(payload))
    return str(p)


def test_masked_token_resolves_from_worker_api_tokens_env(tmp_path):
    from mining_dashboard.config.config import load_worker_endpoints

    p = _write(
        tmp_path,
        {
            "workers": {
                "list": [
                    {"name": "rig1", "host": "10.0.0.5", "token": {"__secret__": True}},
                    {"name": "rig2", "host": "10.0.0.6", "token": {"__secret__": True}},
                ]
            }
        },
    )
    got = load_worker_endpoints(p, tokens_env=json.dumps({"rig1": "the-real-rig1-token"}))
    assert got == [
        {"name": "rig1", "host": "10.0.0.5", "token": "the-real-rig1-token"},
        # rig2 has no entry in the map: stays masked, fail-closed (never a fleet fallback).
        {"name": "rig2", "host": "10.0.0.6", "token": {"__secret__": True}},
    ]


def test_worker_api_tokens_env_ignores_malformed_or_invalid_values(tmp_path):
    from mining_dashboard.config.config import load_worker_endpoints

    p = _write(
        tmp_path,
        {"workers": {"list": [{"name": "rig1", "host": "h", "token": {"__secret__": True}}]}},
    )
    baseline = load_worker_endpoints(p)
    for bad_env in ("not json", "[]", json.dumps({"rig1": "has space"}), json.dumps({"rig1": 5})):
        assert load_worker_endpoints(p, tokens_env=bad_env) == baseline


def test_current_worker_endpoints_merges_worker_api_tokens_env(tmp_path, monkeypatch):
    # End-to-end: current_worker_endpoints() is what the probe actually calls — prove the masked
    # mount + WORKER_API_TOKENS env combination it reads at runtime resolves to the real Bearer,
    # not just the loader function in isolation.
    import mining_dashboard.config.config as cfg

    p = _write(
        tmp_path,
        {
            "workers": {
                "list": [{"name": "rig1", "host": "10.0.0.5", "token": {"__secret__": True}}]
            }
        },
    )
    monkeypatch.setattr(cfg, "HOST_CONFIG_PATH", p)
    monkeypatch.setattr(cfg, "DASHBOARD_WORKERS", None)
    monkeypatch.setenv("WORKER_API_TOKENS", json.dumps({"rig1": "the-real-rig1-token"}))
    assert cfg.current_worker_endpoints() == [
        {"name": "rig1", "host": "10.0.0.5", "token": "the-real-rig1-token"}
    ]
