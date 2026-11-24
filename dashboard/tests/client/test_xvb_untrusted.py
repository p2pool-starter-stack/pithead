from datetime import UTC, datetime, timedelta

import pytest

from mining_dashboard.client.xvb_client import XvbClient, parse_winners

WALLET = "48M2j8GjINNERPARTd8KgGBwa"
ROW = "48M2j8Gj...d8KgGBwa\t{when}\t{rate}\t{height}\t\t{block}\t1/1\t1\tdonor\n"


@pytest.mark.parametrize(
    "page",
    [
        "Fail Count: 0\n24hr avg: 5 kH/s",
        "Fail Count: 2",
        "Fail Count: 0\n1hr avg: " + "9" * 400 + " H/s",
        "Fail Count: " + "9" * 400 + "\n1hr avg: 5 kH/s",
        "Fail Count: 0\n1hr avg: -5 kH/s",
        "1hr avg: . H/s",
        "1hr avg: 5.5.5 H/s",
        "Fail Count: 2 1hr avg: 1.2.3.4 H/s",
        "1hr avg: 1e5 H/s",
    ],
)
def test_a_page_without_a_usable_1h_average_is_no_reading(page):
    assert XvbClient("49abc")._parse_html(page) is None


def test_a_missing_fail_count_still_reads_as_zero():
    stats = XvbClient("49abc")._parse_html("1hr avg: 5 kH/s.")
    assert stats == {"fail_count": 0, "avg_1h": 5000.0, "avg_24h": 0.0}


def test_an_unusable_24h_figure_falls_back_to_zero():
    page = "Fail Count: 1\n1hr avg: 5 kH/s\n24hr avg: " + "9" * 400 + " H/s"
    assert XvbClient("49abc")._parse_html(page) == {
        "fail_count": 1,
        "avg_1h": 5000.0,
        "avg_24h": 0.0,
    }


def test_winners_rows_with_an_absurd_height_or_rate_are_bounded():
    when = "2026-07-18 20:41:38"
    text = ROW.format(when=when, rate="1kH/s", height="9" * 400, block="blk1") + ROW.format(
        when=when, rate="9" * 400 + "H/s", height=5, block="blk2"
    )
    assert parse_winners(text, WALLET) == [
        {"ts": 1784407298.0, "hashrate": 0.0, "height": 5, "block_id": "blk2", "tier": "donor"}
    ]


def test_winners_rows_dated_in_the_future_are_dropped():
    future = (datetime.now(UTC) + timedelta(days=365)).strftime("%Y-%m-%d %H:%M:%S")
    text = ROW.format(when=future, rate="1kH/s", height=1, block="ahead") + ROW.format(
        when="2026-07-18 20:41:38", rate="1kH/s", height=2, block="past"
    )
    assert [win["block_id"] for win in parse_winners(text, WALLET)] == ["past"]
