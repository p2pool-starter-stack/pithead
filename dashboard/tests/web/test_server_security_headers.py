# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestSecurityHeaders:
    async def test_security_headers_present(self, client):
        resp = await client.get("/")
        for h in SECURITY_HEADERS:
            assert h in resp.headers
        assert resp.headers["X-Frame-Options"] == "DENY"

    async def test_csp_has_no_unsafe_inline_or_eval(self, client):
        # The whole app (HTML shell, ES modules, JSON API) is same-origin, so the CSP needs
        # neither 'unsafe-inline' nor 'unsafe-eval' (Issue #60 + rearchitecture).
        csp = (await client.get("/")).headers["Content-Security-Policy"]
        assert "'unsafe-inline'" not in csp
        assert "'unsafe-eval'" not in csp
        assert "script-src 'self'" in csp
        assert "style-src 'self'" in csp

    async def test_state_response_also_carries_headers(self, client):
        # Security headers are applied by middleware to every response, JSON included.
        resp = await client.get("/api/state")
        for h in SECURITY_HEADERS:
            assert h in resp.headers

    def test_apply_security_headers_unit(self):
        resp = MagicMock()
        resp.headers = {}
        _apply_security_headers(resp)
        for h in SECURITY_HEADERS:
            assert h in resp.headers
