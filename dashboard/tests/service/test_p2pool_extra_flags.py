import re
from pathlib import Path

from mining_dashboard.service import control_service


def test_extra_flags_confirmation_mirrors_host():
    root = Path(__file__).resolve().parents[3]
    policy = (root / "lib/pithead/42-control-policy-and-host-checks.sh").read_text()
    named = re.search(r"CONTROL_DASHBOARD_CONFIRM_PATHS='([^']*)'", policy)
    assert named is not None
    assert "p2pool.extra_flags" in named[1].split()
    assert "p2pool.extra_flags" in control_service._confirm_paths({})
    assert "p2pool.extra_flags" not in control_service._editable_paths()
