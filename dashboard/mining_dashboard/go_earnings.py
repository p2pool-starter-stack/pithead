from mining_dashboard import go_overview


def builders(prepared, captured, settings):
    fields = {
        "available",
        "p2pool_hr",
        "p2pool_hr_str",
        "coeff_day",
        "tari_available",
        "tari_coeff_day",
        "tari_difficulty",
        "tari_reward",
        "xvb_day",
        "pool_difficulty",
        "block_reward",
        "disclaimer",
        "confirmed",
        "tari_confirmed",
    }
    if not isinstance(prepared, dict) or set(prepared) != fields:
        raise RuntimeError("native earnings inputs unavailable")

    def earnings(data, metrics, payouts=None, tari_payouts=None, xvb_day=None):
        del data, metrics, payouts, tari_payouts
        return {**prepared, "xvb_day": xvb_day}

    def summary(metrics, earnings, raffle_wins, now=None, expected_wins_day=None, realization=None):
        clock = settings if now is None else {**settings, "now": now}
        captured["earnings_summary"] = go_overview.request(
            "build_earnings_vs_actual",
            [metrics, earnings, raffle_wins, expected_wins_day, realization],
            clock,
        )

    return {"build_earnings": earnings, "build_earnings_vs_actual": summary}
