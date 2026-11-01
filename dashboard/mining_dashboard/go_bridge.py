import logging
import os

from aiohttp import web

from mining_dashboard import go_domain, go_fleet, go_overview, go_views
from mining_dashboard.config import config
from mining_dashboard.web import server
from mining_dashboard.web.views import charts, header

logger = logging.getLogger("GoBridge")


def _state(request):
    return {"domain": go_domain.collect(request.app["latest_data"], request.app["state_manager"])}


async def _finish_state(request):
    prepared = await request.clone(client_max_size=64 << 20).json()
    chart = {}
    series = {}
    presentation = {}
    overview = {}

    def capture(history, shares, range_arg, window, avg_window, **markers):
        chart.update(
            history=history,
            shares=shares,
            range=range_arg,
            window=window,
            avg_window=avg_window,
            now=charts.time.time(),
            update_interval=charts.UPDATE_INTERVAL,
            **markers,
        )

    query = request.query
    state = server.build_state(
        prepared["latest_data"],
        request.app["state_manager"],
        query.get("range", "all"),
        server.parse_window(query.get("from"), query.get("to")),
        server.canonical_window(query.get("avg")),
        chart_builder=capture,
        history=prepared["history"],
        metrics=go_domain.restore(prepared["metrics"]),
        section_builders={
            **go_views.builders(prepared.get("sections", {}), series),
            **go_fleet.builders(presentation),
            **go_overview.builders(overview),
        },
    )
    return {
        "state": state,
        "chart": chart,
        "series": series,
        "presentation": presentation,
        "overview": overview,
    }


def _miner_connection(_request):
    detected = ""
    if config.STRATUM_BIND == "0.0.0.0":
        detected = header.host_display_addr(config.HOST_IP) or ""
    return {
        "HostIP": config.HOST_IP,
        "Bind": config.STRATUM_BIND,
        "Port": config.STRATUM_PORT,
        "DetectedHostIPv4": detected,
        "Password": os.environ.get("PROXY_STRATUM_PASSWORD", ""),
        "TLS": os.environ.get("PROXY_STRATUM_TLS", ""),
        "Fingerprint": os.environ.get("STRATUM_TLS_FINGERPRINT", ""),
    }


def _xvb_standby(request):
    stats = request.app["state_manager"].get_xvb_stats()
    if not isinstance(stats, dict):
        raise TypeError("Invalid XvB statistics")
    return {"stats": stats, "donation_level": config.XVB_DONATION_LEVEL}


def _metrics(request):
    data = request.app["latest_data"] or {}
    state = request.app["state_manager"]
    disk_percent = (data.get("system", {}).get("disk", {}) or {}).get("percent", 0) or 0
    summary = data.get("proxy_summary", {}) or {}
    pool = (data.get("pool", {}) or {}).get("pool", {}) or {}
    return {
        "domain": go_domain.collect(data, state),
        "DiskPercent": disk_percent,
        "DBHealthy": state.is_db_healthy(),
        "share_stats": state.get_share_stats(),
        "SharesAccepted": summary.get("accepted", 0) or 0,
        "SharesRejected": summary.get("rejected", 0) or 0,
        "PoolBlocksFound": pool.get("blocks_found", 0) or 0,
        "SnapshotTS": data.get("timestamp", 0) or 0,
        "Now": charts.time.time(),
    }


def install(app):
    for operation, reader in (
        ("state", _state),
        ("miner-connection", _miner_connection),
        ("xvb-standby", _xvb_standby),
        ("metrics", _metrics),
    ):

        async def handle(request, read=reader):
            try:
                return web.json_response(
                    {"ok": True, "input": read(request)}, headers={"Cache-Control": "no-store"}
                )
            except Exception:
                logger.exception("Error collecting Go dashboard inputs")
                return web.json_response(
                    {"ok": False}, status=500, headers={"Cache-Control": "no-store"}
                )

        app.router.add_get(f"/_go/{operation}", handle)

    async def finish(request):
        try:
            return web.json_response(
                {"ok": True, "input": await _finish_state(request)},
                headers={"Cache-Control": "no-store"},
            )
        except Exception:
            logger.exception("Error building Go dashboard state")
            return web.json_response(
                {"ok": False}, status=500, headers={"Cache-Control": "no-store"}
            )

    app.router.add_post("/_go/state", finish)
