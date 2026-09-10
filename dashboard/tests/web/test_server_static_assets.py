# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestStaticAssets:
    def test_js_mimetypes_registered(self):
        # Importing server registers these so .mjs/.js always serve as JS, even on slim
        # images with no /etc/mime.types (browsers refuse non-JS MIME for modules).
        import mimetypes

        assert "javascript" in (mimetypes.guess_type("app.mjs")[0] or "")
        assert "javascript" in (mimetypes.guess_type("app.js")[0] or "")

    async def test_frontend_modules_served(self, client):
        for path, ctype in (
            ("/static/dashboard.css", "text/css"),
            ("/static/dashboard.js", "javascript"),
            ("/static/app/components.mjs", "javascript"),
            ("/static/app/logic.mjs", "javascript"),
            ("/static/vendor/preact.module.js", "javascript"),
            ("/static/vendor/htm.module.js", "javascript"),
            ("/static/vendor/chartjs-plugin-zoom.min.js", "javascript"),
            ("/static/vendor/hammer.min.js", "javascript"),
        ):
            resp = await client.get(path)
            assert resp.status == 200, path
            assert ctype in resp.headers["Content-Type"], path

    async def test_static_assets_revalidate(self, client):
        # Cache-Control: no-cache makes the browser revalidate, so a rebuilt dashboard's new
        # CSS/JS is picked up on the next load instead of a stale copy lingering (Issue #83).
        resp = await client.get("/static/dashboard.css")
        assert resp.headers.get("Cache-Control") == "no-cache"

    async def test_shell_revalidates(self, client):
        resp = await client.get("/")
        assert resp.headers.get("Cache-Control") == "no-cache"
