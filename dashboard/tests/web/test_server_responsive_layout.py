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

    async def test_hero_value_does_not_break_mid_word(self, client):
        # .hero-value used to share .brand-host's overflow-wrap:anywhere, which licenses a break
        # inside a short word like "P2POOL" on a narrow hero column (#1870) — .brand-host still
        # needs "anywhere" for an unbroken hostname, but the hero tile's short mode/hashrate text
        # doesn't, so it must opt out and instead shrink at the same narrow breakpoint the
        # badge-row scroll strip uses below.
        css = await _served_css(client)
        rule = re.search(r"\.hero-value\s*\{([^}]*)\}", css)
        assert rule and "overflow-wrap: normal" in rule.group(1)
        assert re.search(r"@media[^{]*max-width:\s*720px[^}]*\.hero-value\s*\{[^}]*font-size", css)

    async def test_badge_row_scrolls_only_between_phone_and_720px(self, client):
        # The badge-row scroll strip (#1870) stacks status badges five deep between the phone
        # breakpoint (640px, sync.css) and ~720px. Its selector, `.brand .flex.items-center`
        # (three classes), outranks the phone breakpoint's `.header .items-center` (two classes)
        # on specificity alone — without the `min-width: 641px` lower bound this rule silently
        # overrides the phone tier's row-per-item wrap too, which happened once already inside
        # this PR undetected by CI. Assert the bound is attached to THIS rule, not just present
        # somewhere in the sheet, so removing or detaching it fails here.
        css = await _served_css(client)
        assert re.search(
            r"@media[^{]*min-width:\s*641px[^{]*max-width:\s*720px[^{]*\{"
            r"\s*\.brand \.flex\.items-center\s*\{[^}]*flex-wrap:\s*nowrap[^}]*overflow-x:\s*auto",
            css,
        )

    async def test_host_at_separator_styled_and_rendered(self, client):
        # The "hostname @ ip" subtitle (#119) renders the @ as a dimmed connector span, so the
        # markup must emit `.brand-host-at` and the CSS must carry a matching dimming rule.
        mjs = await (await client.get("/static/app/header.mjs")).text()
        css = await _served_css(client)
        assert "brand-host-at" in mjs and "state.host_addr" in mjs
        assert ".brand-host-at" in css and "opacity" in css
