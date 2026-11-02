from collections import Counter

from mining_dashboard import go_channel
from mining_dashboard.config.config import DEFAULT_HASHRATE_WINDOW

REFERENCE_FUNCTIONS = {}
STATE_KEYS = frozenset(
    "syncing tari_gates_sync page_title host_ip host_addr dashboard_onion version update "
    "control_enabled os_update last_update range window avg_window avg_windows badges db_healthy "
    "hashrate system host_resources sync sync_status stratum pool network monero shares_window "
    "cadence raffle_eligible raffle_wins proxy_workers earnings earnings_summary xvb_calc "
    "xvb_standby tari workers energy proxy_summary share_stats reject_pct_24h blocks payouts "
    "disk_growth xvb_history egress topology chart".split()
)


def _resolve(expression, values):
    if isinstance(expression, dict):
        if set(expression) == {"ref"}:
            index = expression["ref"]
            if type(index) is not int or not 0 <= index < len(values):
                raise RuntimeError("native state returned invalid reference")
            return values[index]
        return {key: _resolve(value, values) for key, value in expression.items()}
    if isinstance(expression, list):
        return [_resolve(value, values) for value in expression]
    return expression


def _assemble(values, slots, *, syncing, tari_required, monero_only, stratum, window):
    pairs = go_channel.call(
        "state",
        {
            "operation": "assemble",
            "input": {
                "slot_count": len(values),
                "syncing": syncing,
                "tari_required": tari_required,
                "monero_only": monero_only,
                "slots": slots,
                "stratum": stratum,
                "window": window,
            },
        },
    )
    if not isinstance(pairs, list) or any(
        not isinstance(pair, list) or len(pair) != 2 or not isinstance(pair[0], str)
        for pair in pairs
    ):
        raise RuntimeError("native state returned invalid fields")
    expected = Counter(STATE_KEYS)
    expected.update(key for key, _index in stratum)
    if Counter(pair[0] for pair in pairs) != expected:
        raise RuntimeError("native state returned incomplete fields")
    for key, value in pairs:
        if isinstance(value, dict) and set(value) == {"ref"}:
            continue
        if key == "page_title" and value in (
            "Pithead Dashboard",
            "Pithead Dashboard - Syncing",
        ):
            continue
        if key == "tari_gates_sync" and type(value) is bool:
            continue
        if key == "window" and (
            value is None
            or isinstance(value, dict)
            and set(value) == {"from", "to"}
            and all(
                isinstance(endpoint, dict) and set(endpoint) == {"ref"}
                for endpoint in value.values()
            )
        ):
            continue
        raise RuntimeError("native state returned invalid field value")
    return {key: _resolve(value, values) for key, value in pairs}


def build_state(
    data,
    state_mgr,
    range_arg,
    window=None,
    avg_window=DEFAULT_HASHRATE_WINDOW,
    *,
    chart_builder=None,
    history=None,
    metrics=None,
    section_builders=None,
    view_snapshot=None,
):
    from mining_dashboard.web.views import views

    values, slots = [], {}

    def save(name, value):
        slots[name] = len(values)
        values.append(value)
        return value

    def section(name, *args, **kwargs):
        return save(name, (section_builders or {}).get(name, getattr(views, name))(*args, **kwargs))

    def view_value(name, default):
        return view_snapshot[name] if view_snapshot and name in view_snapshot else default()

    def timestamped(function, *args, **kwargs):
        if section_builders:
            function = section_builders.get(getattr(function, "__name__", ""), function)
        if view_snapshot:
            kwargs["now"] = now
        return function(*args, **kwargs)

    data = data or {}
    now = view_snapshot["now"] if view_snapshot else None
    history = state_mgr.get_history() if history is None else history
    share_stats = state_mgr.get_share_stats()
    raffle_wins = state_mgr.get_raffle_wins()
    payout_confirm = view_value(
        "payout_confirm_enabled", lambda: views.config.PAYOUT_CONFIRM_ENABLED
    )
    tari_payout_confirm = view_value(
        "tari_payout_confirm_enabled", lambda: views.config.TARI_PAYOUT_CONFIRM_ENABLED
    )
    monero_payouts = state_mgr.get_payouts("monero") if payout_confirm else None
    metrics = views.build_metrics(data, state_mgr, history) if metrics is None else metrics
    db_healthy = state_mgr.is_db_healthy()
    mode_tok, p2p_tok, xvb_tok = views._mode_palette(metrics.mode)
    monero = (section_builders or {}).get("build_monero")
    pool_net = section("build_pool_network", data, metrics, monero)
    earnings = section(
        "build_earnings",
        data,
        metrics,
        payouts=monero_payouts,
        tari_payouts=state_mgr.get_payouts("tari") if tari_payout_confirm else None,
        xvb_day=timestamped(views.xvb_current_tier_reward_day, metrics, state_mgr),
    )
    xvb_wins_day = xvb_realized = None
    if metrics.xvb_enabled:
        xvb_tiers = state_mgr.get_tiers()
        xvb_wins_day = timestamped(
            views.xvb_expected_wins_day,
            state_mgr.get_xvb_round_stats(),
            section("xvb_forecast_tier_key", metrics, xvb_tiers),
            xvb_tiers,
        )
        xvb_realized = timestamped(
            views.xvb_realization,
            monero_payouts,
            raffle_wins,
            earnings["xvb_day"],
            xvb_wins_day,
            p2pool_day=earnings["coeff_day"] * metrics.p2pool_30d,
        )
    save(
        "build_earnings_vs_actual",
        timestamped(
            (section_builders or {}).get(
                "build_earnings_vs_actual", views.build_earnings_vs_actual
            ),
            metrics,
            earnings,
            raffle_wins,
            expected_wins_day=xvb_wins_day,
            realization=xvb_realized,
        ),
    )
    earnings["xvb_day"] = section("xvb_tempered_day", earnings["xvb_day"], xvb_realized)
    egress = view_value("egress", views.egress_posture_from_config)
    topology = view_value("topology", views.topology_from_config)
    badges = section(
        "build_badges",
        data,
        metrics,
        mode_tok,
        db_healthy,
        views.recent_wallet_change(state_mgr, now),
    )
    badges.append(section("_egress_badge", egress["summary"]))
    disk_growth = state_mgr.get_disk_growth()

    save("metrics.global_syncing", metrics.global_syncing)
    tari_required = bool(view_value("tari_required", lambda: views.config.TARI_REQUIRED))
    monero_only = bool(data.get("sync_gate_monero_only")) if tari_required else False
    syncing = bool(metrics.global_syncing)
    save("host_ip", view_value("host_ip", lambda: views.HOST_IP))
    save("host_addr", view_value("host_addr", lambda: views.host_display_addr(views.HOST_IP)))
    save("dashboard_onion", view_value("dashboard_onion", views.dashboard_onion))
    stratum = []
    for key, value in view_value("stratum", views.stratum_state).items():
        save("stratum." + key, value)
        stratum.append([key, slots["stratum." + key]])
    save("version", view_value("version", views.resolve_version))
    section("visible_update", data.get("update"))
    save(
        "control_enabled",
        view_value("control_enabled", lambda: views.config.DASHBOARD_CONTROL_ENABLED),
    )
    save("os_update", view_value("os_update", views.read_os_update_state))
    save(
        "last_update",
        view_value(
            "last_update", lambda: views.format_time_abs(data.get("timestamp") or views.time.time())
        ),
    )
    save("range_arg", range_arg)
    window_refs = None
    if window:
        save("window_from", window[0])
        save("window_to", window[1])
        window_refs = [slots["window_from"], slots["window_to"]]
    save("avg_window", avg_window)
    save("avg_windows", views.HASHRATE_WINDOWS)
    save("badges", badges)
    save("db_healthy", db_healthy)
    section("build_hashrate", metrics, mode_tok, p2p_tok, xvb_tok)
    section("build_system", data)
    section("build_host_resources", data.get("system", {}).get("host_resources", {}), disk_growth)
    section("build_sync", metrics, pool_net["monero"]["db_size"])
    save("sync_status", data.get("sync_status"))
    for field in ("stratum", "pool", "network", "monero", "shares_window"):
        save("pool." + field, pool_net[field])
    section("build_cadence", metrics)
    section("build_raffle_eligibility", metrics)
    section("build_raffle_log", raffle_wins)
    save("metrics.workers_online", metrics.workers_online)
    save(
        "build_xvb_calc",
        timestamped(views.build_xvb_calc, metrics, state_mgr, realization=xvb_realized),
    )
    save("xvb_standby", state_mgr.get_xvb_standby())
    section("build_tari", data)
    section("build_workers", data.get("workers", []), data.get("rigforge_release"))
    section("build_energy", data.get("workers", []), data.get("prices"))
    section("build_proxy_summary", data)
    section("build_share_stats", share_stats, range_arg, window)
    section("_window_reject_pct", share_stats, 24 * 3600)
    section("build_blocks", state_mgr.get_blocks(), range_arg, window)
    section("build_payouts", state_mgr, range_arg, window)
    section("build_disk_growth", disk_growth, range_arg, window)
    section("build_xvb_history", state_mgr.get_xvb_history(), range_arg, window)
    save("egress", egress)
    save("topology", topology)
    save(
        "build_chart",
        (views.build_chart if chart_builder is None else chart_builder)(
            history,
            data.get("shares", []),
            range_arg,
            window,
            avg_window,
            events=state_mgr.get_events(),
            raffle_wins=raffle_wins,
            payouts=monero_payouts,
        ),
    )
    return _assemble(
        values,
        slots,
        syncing=syncing,
        tari_required=tari_required,
        monero_only=monero_only,
        stratum=stratum,
        window=window_refs,
    )


def install():
    from mining_dashboard.web import server
    from mining_dashboard.web.views import views

    REFERENCE_FUNCTIONS.setdefault("build_state", views.build_state)
    views.build_state = server.build_state = build_state
