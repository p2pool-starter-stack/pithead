"""The energy API explains the same conditional gross/net inputs as the dashboard."""

from mining_dashboard.web.views.infra_views import build_energy


def test_energy_disclaimer_includes_tempered_xvb_and_input_qualifications():
    text = build_energy([])["disclaimer"]
    assert "fresh current donor-tier XvB estimate" in text
    assert "same XMR price" in text
    assert "wallet's measured delivery" in text
    assert "measured delivery band's midpoint" in text
    assert "missing or stale estimates are excluded" in text
    assert "merge-mining and a Tari price are available" in text
    assert "CoinGecko-over-Tor feed" in text
    assert "Missing prices leave those figures unavailable" in text
    assert "fleet total is marked incomplete" in text
    assert "Partial power coverage understates cost and can overstate net" in text
    assert "not a metered bill" in text
    assert "payouts vary" in text
    assert "raffle draw is random" in text
    assert "Estimates, not guarantees" in text
    assert "XvB stays excluded" not in text
