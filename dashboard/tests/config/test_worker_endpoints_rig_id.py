import json

import pytest

from mining_dashboard.config.config import load_worker_endpoints

RIG_ID = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"


def _load(tmp_path, workers_list):
    p = tmp_path / "config.json"
    p.write_text(json.dumps({"workers": {"list": workers_list}}))
    return load_worker_endpoints(str(p))


def test_a_valid_rig_id_loads_on_its_entry(tmp_path):
    got = _load(tmp_path, [{"name": "rig1", "host": "10.0.0.5", "rig_id": RIG_ID}])
    assert got == [{"name": "rig1", "host": "10.0.0.5", "rig_id": RIG_ID}]


def test_an_entry_without_a_rig_id_loads_without_the_key(tmp_path):
    assert _load(tmp_path, [{"name": "rig1"}]) == [{"name": "rig1"}]


@pytest.mark.parametrize(
    "bad",
    [
        "",
        "   ",
        "0a1b2c3d4e5f60718293a4b5c6d7e8f",
        "0a1b2c3d4e5f60718293a4b5c6d7e8f90",
        "0A1B2C3D4E5F60718293A4B5C6D7E8F9",
        "g" * 32,
        f"{RIG_ID}\n",
        None,
        123,
        True,
        [],
        {},
    ],
)
def test_an_invalid_rig_id_drops_the_entry_whole(tmp_path, bad):
    got = _load(
        tmp_path,
        [{"name": "rig1", "token": "s3cr3t", "rig_id": bad}, {"name": "rig2"}],
    )
    assert got == [{"name": "rig2"}]


def test_rig_id_does_not_become_a_credential(tmp_path):
    got = _load(tmp_path, [{"name": "rig1", "rig_id": RIG_ID}])
    assert "token" not in got[0]
    assert "api_token" not in got[0]
    assert "read_token" not in got[0]
