# ruff: noqa: F403, F405
import re

from tests.web._server_support import *  # noqa: F403


async def _served_css(client):
    root = await client.get("/static/dashboard.css")
    assert root.status == 200
    css = await root.text()
    for href in re.findall(r'@import "([^"]+)"', css):
        sheet = await client.get(f"/static/{href.removeprefix('./')}")
        assert sheet.status == 200, href
        css += await sheet.text()
    return css


class TestResponsiveLayout:
    """The mobile/responsive layout (Issue #83) is pure CSS + a markup wrapper, with no DOM
    test harness in this repo (rendering is covered by the manual browser smoke test). These
    guard the pieces that have to be present and wired together so the feature can't silently
    regress: the served CSS must carry a phone breakpoint and the horizontal-scroll rule, and
    the workers-table markup must opt into that scroll wrapper."""

    async def test_css_has_phone_breakpoint(self, client):
        css = await _served_css(client)
        # A max-width media query is what makes the layout reflow on phones; without one the
        # only @media block left would be the prefers-color-scheme theme query.
        assert "@media" in css and "max-width" in css

    async def test_css_has_horizontal_scroll_rule(self, client):
        css = await _served_css(client)
        assert ".table-scroll" in css and "overflow-x" in css

    async def test_workers_table_opts_into_scroll_wrapper(self, client):
        # The CSS rule only helps if the markup actually wraps the table in it.
        mjs = await (await client.get("/static/workers/workertable.mjs")).text()
        assert "table-scroll" in mjs

    async def test_css_lets_stat_values_wrap(self, client):
        # The stat-card grid is `1fr 1fr`; without overflow-wrap on the value a long unbroken
        # string (a shortened wallet/hash, "Donor (1.00 kH/s+)") keeps the grid wider than the
        # card and overflows it on a phone. Guard that the wrap rule stays present.
        css = await _served_css(client)
        assert "overflow-wrap" in css

    async def test_css_lets_hostname_wrap(self, client):
        # HOST_IP is arbitrary user input; a long unbroken hostname would push the header (and
        # the page) wider than a phone without a wrap rule. Since #81 the host IP lives in the
        # brand subtitle (`.brand-host`), which carries the overflow-wrap protection.
        css = await _served_css(client)
        assert ".brand-host" in css and "overflow-wrap" in css

    async def test_host_at_separator_styled_and_rendered(self, client):
        # The "hostname @ ip" subtitle (#119) renders the @ as a dimmed connector span, so the
        # markup must emit `.brand-host-at` and the CSS must carry a matching dimming rule.
        mjs = await (await client.get("/static/app/header.mjs")).text()
        css = await _served_css(client)
        assert "brand-host-at" in mjs and "state.host_addr" in mjs
        assert ".brand-host-at" in css and "opacity" in css
