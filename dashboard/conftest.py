import os

import pytest


class _PhasePayload(dict):
    def __missing__(self, key):
        if key == "operation" and isinstance(self.get("phase"), str):
            return self["phase"]
        raise KeyError(key)


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    if os.environ.get("PITHEAD_IMPL") != "go" or not config.pluginmanager.hasplugin(
        "dashboard_channel_plugin"
    ):
        return
    from mining_dashboard import go_channel

    original = go_channel.call

    def counted_payload(helper, payload):
        if helper == "wizard-typed" and "operation" not in payload:
            payload = _PhasePayload(payload)
        return original(helper, payload)

    go_channel.call = counted_payload
