import pytest

from mining_dashboard.web.config_commit import approval_envelope


def test_subaddress_suffix_is_allowed_in_approval_envelope():
    body = {"approve": True, "payout_suffixes": {"monero_subaddress": "suffix"}}
    assert approval_envelope(body) == {"payout_suffixes": {"monero_subaddress": "suffix"}}


def test_unknown_suffix_key_stays_rejected():
    with pytest.raises(ValueError, match="invalid payout confirmation"):
        approval_envelope({"approve": True, "payout_suffixes": {"unknown": "suffix"}})
