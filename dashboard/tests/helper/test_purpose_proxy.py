import pytest

from mining_dashboard.helper.http import (
    PROXY_PURPOSE_DASHBOARD,
    PROXY_PURPOSE_HEALTH,
    PROXY_PURPOSE_NOTIFY,
    PROXY_PURPOSE_UPDATES,
    proxy_map,
    purpose_proxy,
    refuse_direct_public,
)

BASE = "socks5h://tor.test:9050"


def test_constants_are_pinned():
    assert PROXY_PURPOSE_UPDATES == "updates"
    assert PROXY_PURPOSE_HEALTH == "health"
    assert PROXY_PURPOSE_DASHBOARD == "dashboard"
    assert PROXY_PURPOSE_NOTIFY == "notify"


def test_different_purposes_build_different_urls():
    purposes = (
        PROXY_PURPOSE_UPDATES,
        PROXY_PURPOSE_HEALTH,
        PROXY_PURPOSE_DASHBOARD,
        PROXY_PURPOSE_NOTIFY,
    )
    assert len({purpose_proxy(BASE, p) for p in purposes}) == 4


def test_same_label_is_stable():
    assert purpose_proxy(BASE, "updates") == purpose_proxy(BASE, "updates")


def test_userinfo_is_visible_before_the_first_at():
    url = purpose_proxy(BASE, "updates")
    assert url == "socks5h://updates:isolate@tor.test:9050"
    assert url.split("@", 1)[0] == "socks5h://updates:isolate"


def test_only_the_first_scheme_separator_is_rewritten():
    assert purpose_proxy("socks5h://h:1/?u=a://b", "x") == "socks5h://x:isolate@h:1/?u=a://b"


def test_label_is_inserted_verbatim():
    label = "0123456789abcdef0123456789abcdef"
    assert purpose_proxy(BASE, label).startswith(f"socks5h://{label}:isolate@")


@pytest.mark.parametrize("base", ["", "tor.test:9050"])
def test_base_without_a_scheme_raises(base):
    with pytest.raises(ValueError):
        purpose_proxy(base, "updates")


def test_empty_label_raises():
    with pytest.raises(ValueError):
        purpose_proxy(BASE, "")


def test_guard_accepts_a_credentialed_proxy():
    refuse_direct_public("https://api.github.com/x", proxy_map(purpose_proxy(BASE, "updates")))


def test_purpose_proxy_map_passes_an_empty_base_through():
    from mining_dashboard.helper.http import purpose_proxy_map

    assert purpose_proxy_map(None, "notify") == {"http": None, "https": None}
    assert purpose_proxy_map("", "notify") == {"http": "", "https": ""}
    assert purpose_proxy_map(BASE, "notify")["https"] == purpose_proxy(BASE, "notify")
