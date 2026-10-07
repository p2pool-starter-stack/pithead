"""The host inventory, rather than container networking, bounds setup redirects."""

import pytest
from aiohttp import web

from mining_dashboard import wizard_redirect
from tests.web._wizard_support import _plain_request


@pytest.mark.parametrize("inventory", ["", "bad.example", "127.0.0.1 ::1 0.0.0.0 :: fe80::1"])
@pytest.mark.parametrize("claimed", ["evil.example", "10.88.0.2"])
async def test_no_host_inventory_never_redirects_to_the_bridge(monkeypatch, inventory, claimed):
    monkeypatch.setenv("WIZARD_HOST_ADDRESSES", inventory)
    request = _plain_request(claimed, sockname=("10.88.0.2", 8000))
    with pytest.raises(web.HTTPMovedPermanently) as exc:
        await wizard_redirect.redirect_to_tls(request)
    assert exc.value.location == "https://pithead.local/setup"


@pytest.mark.parametrize("claimed", ["evil.example", "10.88.0.2"])
async def test_bridge_header_cannot_win_over_host_inventory(monkeypatch, claimed):
    monkeypatch.setenv("WIZARD_HOST_ADDRESSES", "192.168.1.10 fd00::1")
    request = _plain_request(claimed, sockname=("10.88.0.2", 8000))
    with pytest.raises(web.HTTPMovedPermanently) as exc:
        await wizard_redirect.redirect_to_tls(request)
    assert exc.value.location == "https://192.168.1.10/setup"


@pytest.mark.parametrize("claimed", ["PITHEAD.LOCAL.:80", "setup-box:80", "SETUP-BOX.EXAMPLE.:80"])
def test_owned_names_still_work(monkeypatch, claimed):
    monkeypatch.setenv("WIZARD_HOST_ADDRESSES", "192.168.1.10")
    monkeypatch.setattr(wizard_redirect.socket, "gethostname", lambda: "setup-box")
    monkeypatch.setattr(wizard_redirect.socket, "getfqdn", lambda: "setup-box.example")
    assert wizard_redirect.redirect_host(_plain_request(claimed)) == claimed.rsplit(":", 1)[0]


def test_ipv6_fallback_is_a_valid_url_host(monkeypatch):
    monkeypatch.setenv("WIZARD_HOST_ADDRESSES", "fd00::1")
    assert wizard_redirect.redirect_host(_plain_request("evil.example")) == "[fd00::1]"
