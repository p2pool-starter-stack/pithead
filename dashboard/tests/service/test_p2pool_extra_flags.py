from mining_dashboard.service import control_service


def test_extra_flags_confirmation_metadata():
    assert "p2pool.extra_flags" in control_service._confirm_paths({})
    assert "p2pool.extra_flags" not in control_service._editable_paths()
