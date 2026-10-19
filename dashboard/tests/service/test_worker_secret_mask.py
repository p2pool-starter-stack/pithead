from mining_dashboard.service.control_service import mask_secrets


def test_worker_control_and_probe_tokens_are_masked_in_defense_in_depth_pass():
    config = {
        "workers": {
            "list": [
                {"name": "rig1", "token": "write-secret", "api_token": "read-secret"},
                {"name": "rig2", "token": "", "api_token": ""},
            ]
        }
    }
    mask_secrets(config)
    assert config["workers"]["list"] == [
        {"name": "rig1", "token": {"__secret__": True}, "api_token": {"__secret__": True}},
        {"name": "rig2", "token": "", "api_token": ""},
    ]
