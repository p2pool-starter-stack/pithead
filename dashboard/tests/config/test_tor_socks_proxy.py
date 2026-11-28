import importlib
import os
import subprocess
import sys
from unittest.mock import patch

import pytest

_PROXY_URL = "socks5h://172.28.0.25:9050"


def _reload_config():
    import mining_dashboard.config.config as cfg

    return importlib.reload(cfg)


class TestTorSocksProxy:
    def teardown_method(self):
        _reload_config()

    def test_value_is_read_once_and_stripped(self):
        with patch.dict(os.environ, {"TOR_SOCKS_PROXY": f"  {_PROXY_URL}  "}):
            assert _reload_config().TOR_SOCKS_PROXY == _PROXY_URL

    def test_xvb_tor_socks5_derives_from_the_validated_value(self):
        with patch.dict(os.environ, {"TOR_SOCKS_PROXY": _PROXY_URL}):
            assert _reload_config().XVB_TOR_SOCKS5 == "172.28.0.25:9050"

    def _assert_import_fails(self):
        with pytest.raises(RuntimeError, match="TOR_SOCKS_PROXY"):
            _reload_config()

    def test_empty_value_fails_import_naming_the_variable(self):
        with patch.dict(os.environ, {"TOR_SOCKS_PROXY": ""}):
            self._assert_import_fails()

    def test_whitespace_only_value_fails_import_naming_the_variable(self):
        with patch.dict(os.environ, {"TOR_SOCKS_PROXY": "   "}):
            self._assert_import_fails()

    def test_unset_value_fails_import_naming_the_variable(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TOR_SOCKS_PROXY", None)
            self._assert_import_fails()

    def test_unset_fails_a_fresh_dashboard_import(self):
        env = {k: v for k, v in os.environ.items() if k != "TOR_SOCKS_PROXY"}
        run = subprocess.run(
            [sys.executable, "-c", "import mining_dashboard.config.config"],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )
        assert run.returncode != 0
        assert "TOR_SOCKS_PROXY" in run.stderr
