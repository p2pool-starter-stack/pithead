# ruff: noqa: F821

import json
import os
import sys
from collections import Counter
from functools import wraps
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
os.environ.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))

pytest_plugins = ["dashboard_revision_store_plugin"]

ACCEPTED = Counter()
REFERENCE_FALLBACKS = Counter()
REQUIRED_PLUGINS = (
    "dashboard_storage_plugin",
    "dashboard_http_plugin",
    "dashboard_state_plugin",
    "dashboard_metrics_plugin",
    "dashboard_views_plugin",
    "dashboard_fleet_plugin",
    "dashboard_overview_plugin",
    "dashboard_earnings_plugin",
    "dashboard_forecast_plugin",
    "dashboard_worker_detail_plugin",
    "dashboard_worker_http_plugin",
    "dashboard_polling_plugin",
    "dashboard_assembly_plugin",
    "dashboard_rigforge_plugin",
    "dashboard_preserve_plugin",
    "dashboard_editor_plugin",
    "dashboard_telemetry_plugin",
    "dashboard_host_audit_plugin",
    "dashboard_audit_log_plugin",
    "dashboard_audit_query_plugin",
    "dashboard_access_log_plugin",
    "dashboard_network_plugin",
    "dashboard_egress_status_plugin",
    "dashboard_control_outcomes_plugin",
    "dashboard_audit_cap_plugin",
    "dashboard_config_meta_plugin",
    "dashboard_revision_store_plugin",
    "dashboard_channel_plugin",
    "dashboard_wizard_transaction_plugin",
    "dashboard_wizard_policy_plugin",
    "dashboard_wizard_config_plugin",
    "dashboard_wizard_terminal_plugin",
    "dashboard_wizard_submission_plugin",
    "dashboard_wizard_typed_plugin",
    "dashboard_wizard_values_plugin",
    "dashboard_documents_plugin",
    "dashboard_control_http_plugin",
    "dashboard_wizard_preparation_plugin",
    "dashboard_wizard_state_plugin",
)
HELPER_CLAIMS = {
    "charts": ("charts",),
    "metrics": ("metrics",),
    "views": ("views-series", "views-infra"),
    "fleet": ("fleet", "resources"),
    "overview": ("overview", "badges"),
    "network": ("network-posture", "network-topology", "network-nodes"),
}
GUARDED_CLAIMS = {
    "earnings": "dashboard_earnings_plugin",
    "forecast": "dashboard_forecast_plugin",
    "worker-detail": "mining_dashboard.go_worker_detail",
    "worker-http": "mining_dashboard.go_worker_http",
    "polling": "mining_dashboard.go_polling",
    "assembly": "mining_dashboard.go_state",
    "rigforge": "mining_dashboard.go_rigforge",
    "preserve": "mining_dashboard.go_preserve",
    "editor": "mining_dashboard.go_editor",
    "audit-query": "mining_dashboard.go_audit_query",
    "access-log": "mining_dashboard.go_access_log",
    "network": "mining_dashboard.go_network",
    "egress-status": "mining_dashboard.go_egress_status",
    "control-outcomes": "mining_dashboard.go_control_outcomes",
    "audit-cap": "mining_dashboard.go_audit_cap",
    "config-meta": "mining_dashboard.go_config_meta",
    "revision-store": "mining_dashboard.go_revision_store",
    "wizard-transaction": "mining_dashboard.go_wizard_transaction",
    "wizard-policy": "mining_dashboard.go_wizard_policy",
    "wizard-config": "mining_dashboard.go_wizard_config",
    "wizard-terminal": "mining_dashboard.go_wizard_terminal",
    "wizard-submission": "mining_dashboard.go_wizard_submission",
    "wizard-typed": "mining_dashboard.go_wizard_typed",
    "wizard-values": "mining_dashboard.go_wizard_values",
    "documents": "mining_dashboard.go_documents",
    "control-http": "mining_dashboard.go_control_http",
    "wizard-preparation": "mining_dashboard.go_wizard_preparation",
    "wizard-state": "mining_dashboard.go_wizard_state",
}


def _fatal_count(module_name):
    module = sys.modules.get(module_name)
    if module is None:
        return 0
    references = {
        **getattr(module, "REFERENCE_FUNCTIONS", {}),
        **getattr(module, "REFERENCE_BODIES", {}),
    }
    return bool(references) and all(
        callable(function) and function.__code__.co_name.startswith("_fatal")
        for function in references.values()
    )


def _guarded_results():
    results = {name: _fatal_count(module) for name, module in GUARDED_CLAIMS.items()}
    from mining_dashboard.service import storage_schema

    results["storage"] = all(
        getattr(getattr(storage_schema.StorageSchemaMixin, name), "__name__", "") == "_fatal"
        for name in ("_init_db", "_apply_schema", "_check_integrity", "_migrate_db")
    )
    results["channel"] = _fatal_count("mining_dashboard.go_wizard")
    results["telemetry"] = results.get("polling", 0)
    results["host-audit"] = results.get("polling", 0)
    results["audit-log"] = results.get("polling", 0)
    from mining_dashboard.web import server

    results["public-http"] = all(
        getattr(server, name).__code__.co_name == "_fatal_public_handler"
        for name in (
            "handle_state",
            "handle_miner_connection",
            "handle_xvb_standby",
            "handle_metrics",
        )
    )
    return results


async def _fatal_public_handler(request):
    del request
    _pithead_native_oracle_reference_fallbacks["public-http"] += 1
    raise AssertionError("reference dashboard data handler used in native-oracle mode")


def _guard_reference_app():
    import dashboard_http_plugin

    from mining_dashboard.web import server

    server._pithead_native_oracle_reference_fallbacks = REFERENCE_FALLBACKS
    for name in ("handle_state", "handle_miner_connection", "handle_xvb_standby", "handle_metrics"):
        getattr(server, name).__code__ = _fatal_public_handler.__code__

    original = dashboard_http_plugin.reference_create_app

    def reference_create_app(state_manager, latest_data_ref):
        app = original(state_manager, latest_data_ref)
        routes = {route.resource.canonical for route in app.router.routes()}
        required = {"/_go/state", "/_go/miner-connection", "/_go/xvb-standby", "/_go/metrics"}
        if missing := sorted(required - routes):
            raise RuntimeError(
                "native state bridge routes missing before proxy: " + ", ".join(missing)
            )
        return app

    dashboard_http_plugin.reference_create_app = reference_create_app


def _patch_accounting():
    import dashboard_fleet_plugin
    import dashboard_http_plugin
    import dashboard_metrics_plugin
    import dashboard_network_plugin
    import dashboard_overview_plugin
    import dashboard_state_plugin
    import dashboard_views_plugin

    from mining_dashboard.service import metrics
    from mining_dashboard.web import server
    from mining_dashboard.web.views import charts, views

    original_forward = dashboard_http_plugin.DashboardProxy.forward

    async def forward(self, request):
        response = await original_forward(self, request)
        if request.path == "/api/state" and response.status == 200:
            ACCEPTED["state-route"] += 1
        return response

    dashboard_http_plugin.DashboardProxy.forward = forward

    original_chart = dashboard_state_plugin.native_build_chart

    def chart(*args, **kwargs):
        value = original_chart(*args, **kwargs)
        ACCEPTED["charts"] += 1
        return value

    dashboard_state_plugin.native_build_chart = chart
    charts.build_chart = chart
    views.build_chart = chart

    def wrap_operations(plugin, label):
        for name, function in tuple(plugin.NATIVES.items()):
            result_label = label(name)

            @wraps(function)
            def accepted(*args, _function=function, _label=result_label, **kwargs):
                value = _function(*args, **kwargs)
                ACCEPTED[_label] += 1
                return value

            plugin.NATIVES[name] = accepted
        plugin._set_operations(plugin.NATIVES)

    wrap_operations(
        dashboard_views_plugin,
        lambda name: (
            "views-series" if name in dashboard_views_plugin.SERIES_OPERATIONS else "views-infra"
        ),
    )
    wrap_operations(
        dashboard_fleet_plugin,
        lambda name: "fleet" if name in dashboard_fleet_plugin.FLEET_OPERATIONS else "resources",
    )
    wrap_operations(
        dashboard_overview_plugin,
        lambda name: "badges" if name == "build_badges" else "overview",
    )

    network_labels = {
        "compute_egress_posture": "network-posture",
        "compute_topology": "network-topology",
        "topology_nodes": "network-nodes",
    }
    network_operations = {
        "compute_egress_posture": "posture",
        "compute_topology": "topology-edges",
        "topology_nodes": "topology-nodes",
    }
    for name, function in tuple(dashboard_network_plugin.NATIVES.items()):

        @wraps(function)
        def accepted_network(
            *args,
            _function=function,
            _label=network_labels[name],
            _operation=network_operations[name],
            **kwargs,
        ):
            calls = dashboard_network_plugin.CALLS
            compatibility = dashboard_network_plugin.COMPATIBILITY
            before_calls = calls[_operation]
            before_compatibility = sum(compatibility.values())
            value = _function(*args, **kwargs)
            if _accepted_without_compatibility(
                calls, _operation, compatibility, before_calls, before_compatibility
            ):
                ACCEPTED[_label] += 1
            return value

        dashboard_network_plugin.NATIVES[name] = accepted_network
    dashboard_network_plugin._set(dashboard_network_plugin.NATIVES)

    def metric(function):
        @wraps(function)
        def accepted(*args, **kwargs):
            value = function(*args, **kwargs)
            ACCEPTED["metrics"] += 1
            return value

        return accepted

    dashboard_metrics_plugin.native_avg_p2pool = metric(dashboard_metrics_plugin.native_avg_p2pool)
    dashboard_metrics_plugin.native_avg_xvb = metric(dashboard_metrics_plugin.native_avg_xvb)
    dashboard_metrics_plugin.native_build_metrics = metric(
        dashboard_metrics_plugin.native_build_metrics
    )
    metrics._avg_p2pool_over_window = dashboard_metrics_plugin.native_avg_p2pool
    metrics._avg_xvb_over_window = dashboard_metrics_plugin.native_avg_xvb
    metrics.build_metrics = dashboard_metrics_plugin.native_build_metrics
    server.build_metrics = dashboard_metrics_plugin.native_build_metrics
    views.build_metrics = dashboard_metrics_plugin.native_build_metrics


def _accepted_without_compatibility(
    calls, operation, compatibility, before_calls, before_compatibility
):
    return calls[operation] > before_calls and sum(compatibility.values()) == before_compatibility


def _select_binary():
    binary = Path(os.environ["PITHEAD_DASHBOARD_GO_BINARY"])
    for name in REQUIRED_PLUGINS:
        module = sys.modules.get(name)
        if module is not None and hasattr(module, "BINARY"):
            module.BINARY = binary


@pytest.hookimpl(hookwrapper=True, trylast=True)
def pytest_sessionstart(session):
    _select_binary()
    yield
    if os.environ.get("PITHEAD_IMPL") != "go":
        raise pytest.UsageError("native-oracle requires PITHEAD_IMPL=go")
    missing = [
        name for name in REQUIRED_PLUGINS if not session.config.pluginmanager.hasplugin(name)
    ]
    if missing:
        raise pytest.UsageError("native-oracle plugins missing: " + ", ".join(missing))
    import dashboard_http_plugin

    factory = dashboard_http_plugin._ORIGINAL_CREATE_APP
    if factory is None or factory.__module__ != "dashboard_state_plugin":
        raise pytest.UsageError("native state bridge was not installed before the HTTP proxy")
    _guard_reference_app()
    _patch_accounting()


def pytest_sessionfinish(session):
    report = [dict(ACCEPTED), _guarded_results(), dict(REFERENCE_FALLBACKS)]
    if hasattr(session.config, "workeroutput"):
        session.config.workeroutput["native_oracle"] = report
        return
    _enforce(session, *report)


@pytest.hookimpl(optionalhook=True)
def pytest_testnodedown(node, error):
    del error
    if report := node.workeroutput.get("native_oracle"):
        ACCEPTED.update(report[0])
        REFERENCE_FALLBACKS.update(report[2])


def _enforce(session, accepted, guarded, reference_fallbacks):
    failures = []
    if not accepted.get("state-route"):
        failures.append("state-route:no accepted native response")
    for claim, helpers in HELPER_CLAIMS.items():
        missing = [helper for helper in helpers if not accepted.get(helper)]
        if missing:
            failures.append(f"{claim}:no accepted {','.join(missing)} result")
    failures.extend(
        f"{claim}:reference body is not fatal" for claim, count in guarded.items() if not count
    )
    failures.extend(
        f"{claim}:reference fallback executed {count} times"
        for claim, count in reference_fallbacks.items()
        if count
    )
    if failures:
        session.exitstatus = pytest.ExitCode.TESTS_FAILED
        session.config._native_oracle_failures = failures


@pytest.hookimpl(trylast=True)
def pytest_terminal_summary(terminalreporter):
    terminalreporter.write_sep(
        "=", "strict native oracle accepted " + json.dumps(dict(ACCEPTED), sort_keys=True)
    )
    terminalreporter.write_line(
        "strict native oracle reference fallbacks "
        + json.dumps(dict(REFERENCE_FALLBACKS), sort_keys=True)
    )
    if failures := getattr(terminalreporter.config, "_native_oracle_failures", None):
        terminalreporter.write_line("strict native oracle failures " + json.dumps(failures))
