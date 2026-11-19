# ruff: noqa: F403, F405
from tests.web._wizard_support import *  # noqa: F403


async def test_rig_tls_paired_and_fingerprint_land_as_typed_json(client, seeded):
    await _auth(client)
    fp = "0" * 64
    r = await client.post(
        "/submit",
        data={
            "role": "rig",
            "rig_pool": "pool.example:5555",
            "rig_tls": "1",
            "rig_tls_fingerprint": fp,
            "rig_paired": "0",
        },
    )
    assert r.status == 200
    assert json.loads((seeded / "rig-request.json").read_text()) == {
        "pool": "pool.example:5555",
        "tls": True,
        "tls_fingerprint": fp,
        "paired": False,
    }


async def test_rig_tls_zero_lands_false_and_uppercase_fingerprint_is_accepted(client, seeded):
    await _auth(client)
    r = await client.post(
        "/submit",
        data={
            "role": "rig",
            "rig_pool": "10.0.0.5:3333",
            "rig_tls": "0",
            "rig_paired": "1",
            "rig_tls_fingerprint": "A" * 64,
        },
    )
    assert r.status == 200
    assert json.loads((seeded / "rig-request.json").read_text()) == {
        "pool": "10.0.0.5:3333",
        "tls": False,
        "paired": True,
        "tls_fingerprint": "A" * 64,
    }


async def test_rig_wrong_typed_pool_kind_fields_are_refused(client, seeded):
    await _auth(client)
    cases = (
        {"rig_tls": "yes"},
        {"rig_tls": "2"},
        {"rig_paired": "onoff"},
        {"rig_tls_fingerprint": "abc"},
        {"rig_tls_fingerprint": "a" * 63},
        {"rig_tls_fingerprint": "g" * 64},
        {"rig_tls_fingerprint": "0" * 64 + "0"},
    )
    for bad in cases:
        r = await client.post("/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333", **bad})
        assert r.status == 400, bad
        assert not (seeded / "rig-request.json").exists()


async def test_rig_submit_clears_a_previous_rig_warning(client, seeded):
    await _auth(client)
    (seeded / "rig-warning.txt").write_text("cannot reach a pool at 10.0.0.9:3333")
    r = await client.post("/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333"})
    assert r.status == 200
    assert not (seeded / "rig-warning.txt").exists()
