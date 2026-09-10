# ruff: noqa: F401
"""Server contracts of the first-boot wizard (#77 phase 3).

The wizard is an SPA on the dashboard's frontend stack; the server renders no HTML. These
tests pin what the SERVER promises — the token gate, the state API, the spool writes the host
consumes, the guards on the destructive install path, and TLS selection. Everything the
operator SEES is preact components, whose pure logic is tested where the dashboard tests its
frontend: node --test over configsync.mjs.
"""

import json

import pytest
from aiohttp import FormData, web
from aiohttp.test_utils import TestClient, TestServer, make_mocked_request

from mining_dashboard.wizard import server as wizard


@pytest.fixture
def spool(tmp_path, monkeypatch):
    sd = tmp_path / "spool"
    sd.mkdir()
    monkeypatch.setenv("WIZARD_SPOOL", str(sd))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    return sd


@pytest.fixture
async def client(spool):
    exits = []
    app = wizard.make_app(exit_fn=lambda code: exits.append(code))
    app["exits"] = exits
    c = TestClient(TestServer(app))
    await c.start_server()
    yield c
    await c.close()


@pytest.fixture
def seeded(spool):
    """A published reference, as the host provides on a real machine."""
    spool.joinpath("config.reference.json").write_text(
        json.dumps(
            {
                "monero": {"wallet_address": "", "mode": "local", "prune": True},
                "tari": {"wallet_address": "", "mode": "local"},
                "p2pool": {"pool": "mini"},
                "tor": {"auto_heal": False},
            }
        )
    )
    return spool


@pytest.fixture
def installer(spool):
    spool.joinpath("disks.tsv").write_text(
        "nvme0n1\t931.5G\tSamsung SSD 990\tS6P1NF0T\tempty\n"
        "sda\t3.6T\tWDC WD40EFRX\tWD-WCC7K3\tpithead-with-data\n"
    )
    return spool


async def _auth(client, token="pit-X7KM2Q"):  # noqa: S107 — the test fixture's token, not a secret
    return await client.post("/auth", data={"token": token}, allow_redirects=False)


_CFG = '{"monero": {"wallet_address": "4' + "A" * 94 + '"}, "tari": {"wallet_address": "t"}}'


async def _submit_install(client, disk="nvme0n1", confirm=None, wipe=None):
    data = {"config": _CFG, "disk": disk, "confirm": confirm if confirm is not None else disk}
    if wipe is not None:
        data["wipe"] = wipe
    return await client.post("/submit", data=data)


class _Transport:
    """Just enough transport to answer "what address did this arrive on"."""

    def __init__(self, sockname):
        self._sockname = sockname

    def get_extra_info(self, name, default=None):
        return self._sockname if name == "sockname" and self._sockname else default


def _plain_request(host, sockname=("192.168.1.10", 80)):
    """A :80 request claiming `host`, arriving on `sockname` — the two the redirect weighs."""
    return make_mocked_request(
        "GET", "/setup", headers={"Host": host}, transport=_Transport(sockname)
    )


def _archive_form(data=b"Salted__fixture-ciphertext", passphrase="hunter2", **extra):  # noqa: S107
    form = FormData()
    form.add_field(
        "archive", data, filename="backup.tar.gz.enc", content_type="application/octet-stream"
    )
    form.add_field("passphrase", passphrase)
    for k, v in extra.items():
        form.add_field(k, v)
    return form


__all__ = [name for name in globals() if not name.startswith("__")]
