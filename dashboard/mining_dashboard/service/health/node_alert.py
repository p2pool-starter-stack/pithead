from mining_dashboard.service.health.tor_heal import BROKEN_AFTER_SEC, COOLDOWN_SEC, MAX_ATTEMPTS

TITLE = "Monero node offline"
DOCTOR_ADVICE = "Run './pithead doctor' for current evidence."


def _minutes(seconds):
    return max(int(seconds // 60), 0)


def tor_heal_status(healer):
    if not healer.enabled:
        return {"enabled": False}
    now = healer._clock()
    failing_since = healer._failing_since
    last_attempt = healer._last_attempt
    return {
        "enabled": True,
        "broken_sec": None if failing_since is None else int(now - failing_since),
        "attempts": healer._attempts,
        "last_action": healer._recovery_step,
        "last_action_age_sec": None if last_attempt is None else int(now - last_attempt),
    }


def _heal_lines(heal):
    if not heal.get("enabled"):
        return []
    attempts = heal.get("attempts") or 0
    if not attempts:
        return ["Tor auto-heal: no action taken yet."]
    age = heal.get("last_action_age_sec")
    action = heal.get("last_action") or "recovery attempt"
    lines = [
        f"Tor auto-heal last action: {action}"
        + ("" if age is None else f", {_minutes(age)} min ago")
        + f" (attempt {attempts} of {MAX_ATTEMPTS})."
    ]
    if attempts >= MAX_ATTEMPTS:
        lines.append(
            f"Tor auto-heal stopped after {MAX_ATTEMPTS} attempts; no more automatic action "
            f"this outage. {DOCTOR_ADVICE}"
        )
    elif age is not None and age < COOLDOWN_SEC:
        lines.append(f"Next action after a {_minutes(COOLDOWN_SEC - age)} min cooldown.")
    return lines


def build_node_alert(data):
    health = (data.get("monero_sync") or {}).get("health") or {}
    heal = data.get("tor_heal") or {}
    reasons = []
    if health.get("level") == "red":
        reasons.extend(health.get("reasons") or [])
    broken = heal.get("broken_sec")
    if broken is not None and broken >= BROKEN_AFTER_SEC:
        reasons.append(f"Tor clearnet egress has failed for {_minutes(broken)} min")
    if not reasons:
        return None
    return {"title": TITLE, "reasons": reasons, "heal": _heal_lines(heal)}
