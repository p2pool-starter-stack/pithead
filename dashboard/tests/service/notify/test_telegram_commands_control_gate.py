# ruff: noqa: F403, F405
from tests.service.notify._telegram_commands_support import *  # noqa: F403


class TestControlGate:
    """The per-action confirm / deny-on-timeout / rate-limit state machine, clock-injected."""

    def test_confirm_within_window_returns_verb(self):
        gate = tc.ControlGate(timeout_s=60)
        token = gate.open("restart", "7", now=0)
        assert token is not None
        assert gate.confirm(token, "7", now=30) == "restart"

    def test_deny_on_timeout(self):
        # An unconfirmed action is DENIED once the window lapses — never queued (fail-closed).
        gate = tc.ControlGate(timeout_s=60)
        token = gate.open("apply", "7", now=0)
        assert gate.confirm(token, "7", now=61) is None

    def test_confirm_from_a_different_user_denied(self):
        # Only the operator who issued the command may confirm it.
        gate = tc.ControlGate(timeout_s=60)
        token = gate.open("restart", "7", now=0)
        assert gate.confirm(token, "9", now=1) is None

    def test_token_is_one_shot(self):
        gate = tc.ControlGate(timeout_s=60)
        token = gate.open("restart", "7", now=0)
        assert gate.confirm(token, "7", now=1) == "restart"
        # A second tap on the same button can't replay the action.
        assert gate.confirm(token, "7", now=2) is None

    def test_unknown_token_denied(self):
        gate = tc.ControlGate(timeout_s=60)
        assert gate.confirm("deadbeef", "7", now=0) is None

    def test_rate_limited_after_max_prompts(self):
        gate = tc.ControlGate(timeout_s=60, max_prompts_per_hour=3)
        assert all(gate.open("restart", "7", now=i) for i in range(3))
        # 4th prompt inside the hour is refused (None), so a spammer can't fatigue the operator.
        assert gate.open("restart", "7", now=3) is None
        # An hour later there is room again.
        assert gate.open("restart", "7", now=3601) is not None

    def test_rate_limit_is_per_operator(self):
        # #470: one operator exhausting the budget must NOT lock the others out — the budget is
        # keyed by user id, not a single global list.
        gate = tc.ControlGate(timeout_s=60, max_prompts_per_hour=2)
        assert all(gate.open("restart", "7", now=i) for i in range(2))
        assert gate.open("restart", "7", now=2) is None  # operator 7 is now capped
        # A different operator still has their full budget.
        assert gate.open("apply", "42", now=2) is not None
        assert gate.open("apply", "42", now=3) is not None
        assert gate.open("apply", "42", now=4) is None  # 42 caps independently
