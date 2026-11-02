import os
import sys
from pathlib import Path

import dashboard_network_plugin as adapter
import pytest
from dashboard_network_compare import SAFE
from dashboard_network_session import NetworkSession

from mining_dashboard import go_network
from mining_dashboard.service.network import egress, topology, topology_graph

# ruff: noqa: S101

pytest_plugins = ["dashboard_network_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


@pytest.mark.parametrize(
    ("field", "value", "reason"),
    [
        ("firewall", 1, "compute_egress_posture:boolean-shape"),
        ("monero_route", object(), "compute_egress_posture:route-shape"),
        ("monero_route", "invalid", "compute_egress_posture:route-value"),
        ("xvb_standby_source", object(), "compute_egress_posture:standby-source"),
    ],
)
def test_explicit_posture_compatibility(monkeypatch, field, value, reason):
    arguments = {**SAFE, field: value}
    before = adapter.COMPATIBILITY[reason]

    def outcome(function):
        try:
            return "value", function(**arguments)
        except Exception as error:
            return "error", type(error), str(error)

    with adapter.python_operations():
        expected = outcome(adapter.ORIGINALS["compute_egress_posture"])
    actual = outcome(egress.compute_egress_posture)
    assert actual == expected
    assert adapter.COMPATIBILITY[reason] == before + 1


def test_replaced_route_provider_is_explicit_compatibility(monkeypatch):
    original = egress._xvb_route
    monkeypatch.setattr(egress, "_xvb_route", lambda enabled, tor: original(enabled, tor))
    before = adapter.COMPATIBILITY["compute_egress_posture:xvb-route-provider"]
    assert egress.compute_egress_posture(**SAFE)["summary"]["all_tor"] is True
    assert adapter.COMPATIBILITY["compute_egress_posture:xvb-route-provider"] == before + 1


def test_replaced_graph_route_constant_is_explicit_compatibility(monkeypatch):
    monkeypatch.setattr(topology_graph, "CLEARNET", "changed")
    before = adapter.COMPATIBILITY["compute_egress_posture:graph-route-provider"]
    assert egress.compute_egress_posture(**SAFE)["summary"]["all_tor"] is True
    assert adapter.COMPATIBILITY["compute_egress_posture:graph-route-provider"] == before + 1


def test_topology_calls_current_posture_first_then_graph_helpers(monkeypatch):
    order = []
    posture = topology.compute_egress_posture
    call = go_network.go_channel.call

    def current(**values):
        order.append("posture")
        return posture(**values)

    def observed(helper, payload):
        order.append(payload["operation"])
        return call(helper, payload)

    monkeypatch.setattr(topology, "compute_egress_posture", current)
    monkeypatch.setattr(go_network.go_channel, "call", observed)
    topology.compute_topology(**{**SAFE, "local_miner_enabled": False})
    assert order == ["posture", "posture", "topology-edges", "topology-nodes"]


def test_topology_provider_failure_keeps_posture_prefix(monkeypatch):
    seen = []
    monkeypatch.setattr(
        topology,
        "compute_egress_posture",
        lambda **_values: seen.append("posture") or {"summary": {}, "components": []},
    )
    monkeypatch.setattr(
        topology, "edge", lambda *_args: (_ for _ in ()).throw(RuntimeError("edge failed"))
    )
    with pytest.raises(RuntimeError, match="edge failed"):
        topology.compute_topology(**{**SAFE, "local_miner_enabled": False})
    assert seen == ["posture"]


def test_long_stratum_label_does_not_repeat_route_providers(monkeypatch):
    calls = []
    providers = {
        "xvb-route": egress._xvb_route,
        "notify-route": egress._notify_route,
        "standby-route": egress._xvb_standby_route,
    }

    def xvb(*args):
        calls.append("xvb")
        return providers["xvb-route"](*args)

    def notify(*args):
        calls.append("notify")
        return providers["notify-route"](*args)

    def standby(*args):
        calls.append("standby")
        return providers["standby-route"](*args)

    replacements = {"xvb-route": xvb, "notify-route": notify, "standby-route": standby}
    for module in (egress, topology):
        monkeypatch.setattr(module, "_xvb_route", xvb)
        monkeypatch.setattr(module, "_notify_route", notify)
        monkeypatch.setattr(module, "_xvb_standby_route", standby)
    for name, function in replacements.items():
        monkeypatch.setitem(go_network.PROVIDERS, name, function)
    monkeypatch.setattr(topology.config, "STRATUM_PORT", "x" * 300)
    before = adapter.COMPATIBILITY["compute_topology:stratum-port"]
    result = topology.compute_topology(**{**SAFE, "local_miner_enabled": False})
    assert result["edges"][0]["label"] == "stratum :" + "x" * 300
    assert calls == ["xvb", "notify", "standby", "xvb", "notify", "standby"]
    assert adapter.COMPATIBILITY["compute_topology:stratum-port"] == before + 1


def test_large_escaped_node_request_uses_explicit_compatibility():
    base = topology_graph.TOPOLOGY_NODES
    saved = list(base)
    try:
        base[:] = [{"id": "\\" * 256, "zone": "\\" * 256} for _ in range(4096)]
        before_reason = adapter.COMPATIBILITY["topology_nodes:node-request-size"]
        before_calls = adapter.CALLS["topology-nodes"]
        nodes = topology_graph.topology_nodes(monero_route="local", tari_route="local")
        assert nodes == base
        assert all(node is original for node, original in zip(nodes, base, strict=True))
        assert adapter.COMPATIBILITY["topology_nodes:node-request-size"] == before_reason + 1
        assert adapter.CALLS["topology-nodes"] == before_calls
    finally:
        base[:] = saved


@pytest.mark.parametrize("operation", ["posture", "topology-edges", "topology-nodes"])
def test_native_failures_are_fatal(monkeypatch, operation):
    call = go_network.go_channel.call

    def failed(helper, payload):
        if payload["operation"] == operation:
            raise RuntimeError("transport failed")
        return call(helper, payload)

    monkeypatch.setattr(go_network.go_channel, "call", failed)
    if operation == "posture":

        def target():
            return egress.compute_egress_posture(**SAFE)

    elif operation == "topology-edges":

        def target():
            return topology.compute_topology(**{**SAFE, "local_miner_enabled": False})

    else:

        def target():
            return topology_graph.topology_nodes(monero_route="local", tari_route="local")

    with pytest.raises(RuntimeError, match="transport failed"):
        target()


def test_malformed_native_reply_is_fatal(monkeypatch):
    monkeypatch.setattr(go_network.go_channel, "call", lambda *_args, **_kwargs: {})
    with pytest.raises(RuntimeError, match="invalid posture"):
        egress.compute_egress_posture(**SAFE)


def test_stream_continues_after_operation_error():
    with pytest.raises(ValueError, match="unsupported network operation"):
        adapter.SESSION.call({"operation": "invalid"})
    assert egress.compute_egress_posture(**SAFE)["summary"]["all_tor"] is True


def test_stream_closes_and_recovers_after_oversized_line():
    root = Path(__file__).resolve().parents[2]
    session = NetworkSession(go_network.go_channel.binary(), root)
    try:
        with pytest.raises(RuntimeError, match="stopped"):
            session.call({"operation": "posture", "padding": "x" * ((2 << 20) + 1)})
        with pytest.raises(ValueError, match="missing network policy input"):
            session.call({"operation": "posture"})
    finally:
        session.close()
    with pytest.raises(RuntimeError, match="closed"):
        session.call({"operation": "posture"})


@pytest.mark.parametrize(
    ("body", "message", "reply_limit"),
    [
        ("stream.write(b'{\"ok\":'); stream.flush(); time.sleep(5)", "timed out", 4096),
        ("stream.write(b'x' * 1025); stream.flush(); time.sleep(5)", "exceeds size limit", 512),
        (
            "stream.write(b'{\"ok\":true,\"value\":\"' + b'x' * 1025 + b'\"}\\n'); stream.flush()",
            "exceeds size limit",
            512,
        ),
        ("stream.write(b'not json\\n'); stream.flush()", "invalid data", 4096),
    ],
)
def test_stream_rejects_partial_oversized_and_malformed_replies(
    tmp_path, body, message, reply_limit
):
    binary = tmp_path / "fake-network"
    binary.write_text(
        f"#!{sys.executable}\nimport sys, time\n"
        "stream = sys.stdout.buffer\n"
        "sys.stdin.buffer.readline()\n"
        f"{body}\n"
    )
    binary.chmod(0o755)
    session = NetworkSession(binary, tmp_path, timeout=1, reply_limit=reply_limit)
    try:
        with pytest.raises(RuntimeError, match=message):
            session.call({"operation": "posture"})
        assert session._process is None
    finally:
        session.close()


def test_stream_constructor_does_not_leave_state_after_launch_error(tmp_path):
    with pytest.raises(OSError):
        NetworkSession(tmp_path / "missing", tmp_path)


def test_install_is_idempotent():
    originals = dict(go_network.REFERENCE_FUNCTIONS)
    go_network.install()
    assert go_network.REFERENCE_FUNCTIONS == originals
    assert egress.compute_egress_posture is go_network.compute_egress_posture
