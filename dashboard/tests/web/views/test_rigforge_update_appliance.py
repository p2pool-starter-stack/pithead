from datetime import UTC, datetime

from mining_dashboard.web.views.infra_views import rigforge_update_for

_REL = {"tag": "v1.11.2", "url": "https://h/v1.11.2"}
_CALLOUT = {"available": True, "latest": "v1.11.2", "url": "https://h/v1.11.2"}


def _worker(**rf_extra):
    feed = {
        "generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "version": "1.11.0",
        **rf_extra,
    }
    return {"name": "rig1", "status": "online", "rigforge": feed}


def test_appliance_rig_never_gets_the_callout():
    assert rigforge_update_for(_worker(appliance=True), _REL) is None


def test_non_appliance_rig_behind_still_gets_the_callout():
    assert rigforge_update_for(_worker(appliance=False), _REL) == _CALLOUT


def test_key_absent_still_gets_the_callout():
    assert rigforge_update_for(_worker(), _REL) == _CALLOUT
