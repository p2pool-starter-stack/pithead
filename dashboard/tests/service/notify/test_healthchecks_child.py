import io
import json
import runpy
from unittest.mock import MagicMock, patch

import pytest
import requests

from mining_dashboard.service.notify import healthchecks_child as child

REQUEST = {
    "url": "https://hc-ping.com/abc",
    "proxy": "socks5h://tor:9050",
    "timeout": 5,
    "deadline": 9,
}


def _run(monkeypatch, capsys, **patches):
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(patches.pop("request", REQUEST))))
    with patch.object(child, "bounded_get", **patches) as get:
        child.main()
    return json.loads(capsys.readouterr().out), get


def test_a_reply_status_is_reported_and_the_proxy_is_passed_on(monkeypatch, capsys):
    out, get = _run(monkeypatch, capsys, return_value=MagicMock(status_code=200))
    assert out == {"status": 200}
    assert get.call_args.kwargs["proxies"] == {
        "http": "socks5h://tor:9050",
        "https": "socks5h://tor:9050",
    }
    assert get.call_args.kwargs["deadline"] == 9


def test_no_proxy_passes_an_unusable_proxy_map(monkeypatch, capsys):
    out, get = _run(
        monkeypatch,
        capsys,
        request={**REQUEST, "proxy": None},
        return_value=MagicMock(status_code=204),
    )
    assert out == {"status": 204}
    assert get.call_args.kwargs["proxies"] == {"http": None, "https": None}


def test_a_request_failure_reports_its_class_and_name(monkeypatch, capsys):
    out, _ = _run(monkeypatch, capsys, side_effect=requests.exceptions.ProxyError("x"))
    assert out == {"reason": "tor_socks", "name": "ProxyError"}


def test_an_unexpected_error_reports_connect(monkeypatch, capsys):
    out, _ = _run(monkeypatch, capsys, side_effect=ValueError("x"))
    assert out == {"reason": "connect", "name": "ValueError"}


@pytest.mark.filterwarnings("ignore::RuntimeWarning")
def test_the_module_runs_as_a_script(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({**REQUEST, "proxy": None})))
    with patch("mining_dashboard.helper.http.bounded_get", return_value=MagicMock(status_code=200)):
        runpy.run_module(child.__name__, run_name="__main__")
    assert json.loads(capsys.readouterr().out) == {"status": 200}
