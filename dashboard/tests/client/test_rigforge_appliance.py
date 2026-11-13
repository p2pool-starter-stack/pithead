from mining_dashboard.client.xmrig_client import parse_rigforge


def _payload(**rf_extra):
    return {"rigforge": {"version": "1.11.0", "xmrig_api": "ok", **rf_extra}}


def test_appliance_and_stamp_carry_through():
    parsed = parse_rigforge(_payload(appliance=True, stamp="v1.12.0"))
    assert parsed["appliance"] is True
    assert parsed["stamp"] == "v1.12.0"


def test_appliance_false_and_null_stamp_parse_as_today():
    parsed = parse_rigforge(_payload(appliance=False, stamp=None))
    assert parsed["appliance"] is False
    assert parsed["stamp"] is None


def test_keys_absent_degrade_to_today():
    parsed = parse_rigforge(_payload())
    assert parsed["appliance"] is False
    assert parsed["stamp"] is None
