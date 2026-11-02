import json
from types import FunctionType, SimpleNamespace

from mining_dashboard import go_channel
from mining_dashboard.go_network_validation import (
    utf8_within as _utf8_within,
)
from mining_dashboard.go_network_validation import (
    validate_edges as _validate_edges,
)
from mining_dashboard.go_network_validation import (
    validate_posture as _validate_posture,
)

REFERENCE_FUNCTIONS = {}
COMPAT_FUNCTIONS = {}
PROVIDERS = {}
_BOOL_FIELDS = (
    "firewall",
    "p2pool_clearnet",
    "xvb_enabled",
    "xvb_tor",
    "monero_clearnet_sync",
    "tari_clearnet_sync",
    "tari_enabled",
    "healthchecks_enabled",
    "telegram_enabled",
    "price_feed_enabled",
    "notify_sinks_enabled",
    "notify_tor",
    "notify_sinks_private",
    "tor_auto_heal",
    "tari_explorer",
)
_ROUTE_NAMES = ("TOR", "CLEARNET", "INCOMING", "LOCAL", "LAN", "UNKNOWN", "INACTIVE")
_MODULE_ROUTE_NAMES = {
    "egress": ("TOR", "CLEARNET", "LOCAL", "UNKNOWN", "INACTIVE"),
    "topology": ("TOR", "CLEARNET", "INCOMING", "LOCAL", "INACTIVE"),
}
_GRAPH_NAMES = (*_ROUTE_NAMES, "ZONE_REMOTE")
_NATIVE_MAX_NODES = 4096
_NATIVE_MAX_REQUEST_BYTES = 2 << 20


def _clone(function, globals_=None):
    value = FunctionType(
        function.__code__,
        globals_ or function.__globals__,
        function.__name__,
        function.__defaults__,
        function.__closure__,
    )
    value.__kwdefaults__ = function.__kwdefaults__
    value.__dict__.update(function.__dict__)
    return value


def _compat(name, reason, *args, **kwargs):
    del reason
    return COMPAT_FUNCTIONS[name](*args, **kwargs)


def _route_values():
    return set(PROVIDERS["graph:NODE_ROUTES"]) | {
        PROVIDERS["graph:TOR"],
        PROVIDERS["graph:INCOMING"],
        PROVIDERS["graph:INACTIVE"],
    }


def _reason(arguments, providers):
    if any(type(arguments[field]) is not bool for field in _BOOL_FIELDS):
        return "boolean-shape"
    if any(type(arguments[field]) is not str for field in ("monero_route", "tari_route")):
        return "route-shape"
    if any(arguments[field] not in _route_values() for field in ("monero_route", "tari_route")):
        return "route-value"
    if type(arguments["xvb_standby_source"]) is not str:
        return "standby-source"
    for name, current in providers.items():
        if current is not PROVIDERS[name]:
            return name + "-provider"
    return None


def _constant_reason(module, prefix):
    if any(
        getattr(module, name) != PROVIDERS[f"{prefix}:{name}"]
        for name in _MODULE_ROUTE_NAMES[prefix]
    ):
        return prefix + "-route-provider"
    return None


def _graph_constant_reason():
    from mining_dashboard.service.network import topology_graph

    if topology_graph.NODE_ROUTES != PROVIDERS["graph:NODE_ROUTES"] or any(
        getattr(topology_graph, name) != PROVIDERS[f"graph:{name}"] for name in _GRAPH_NAMES
    ):
        return "graph-route-provider"
    return None


def _request(operation, arguments, standby_route, **extra):
    payload = {"operation": operation}
    payload.update({field: arguments[field] for field in _BOOL_FIELDS})
    payload.update(
        monero_route=arguments["monero_route"],
        tari_route=arguments["tari_route"],
        standby_route=standby_route,
        **extra,
    )
    return go_channel.call("network", payload)


def _valid_route(value):
    return type(value) is str and value in _route_values()


def _arguments(locals_):
    return {
        field: locals_[field]
        for field in (*_BOOL_FIELDS, "monero_route", "tari_route", "xvb_standby_source")
    }


def compute_egress_posture(
    *,
    firewall,
    p2pool_clearnet,
    xvb_enabled,
    xvb_tor,
    monero_clearnet_sync,
    tari_clearnet_sync,
    monero_route,
    tari_route="local",
    tari_enabled=True,
    healthchecks_enabled,
    telegram_enabled,
    price_feed_enabled=False,
    notify_sinks_enabled=False,
    notify_tor=True,
    notify_sinks_private=False,
    xvb_standby_source="",
    tor_auto_heal=False,
    tari_explorer=False,
):
    from mining_dashboard.service.network import egress

    arguments = _arguments(locals())
    providers = {
        "xvb-route": egress._xvb_route,
        "notify-route": egress._notify_route,
        "standby-route": egress._xvb_standby_route,
    }
    reason = (
        _graph_constant_reason()
        or _constant_reason(egress, "egress")
        or _reason(arguments, providers)
    )
    if reason:
        return _compat("compute_egress_posture", reason, **arguments)
    xvb = egress._xvb_route(xvb_enabled, xvb_tor)
    sinks = egress._notify_route(notify_sinks_enabled, notify_tor, notify_sinks_private)
    standby = egress._xvb_standby_route(xvb_standby_source)
    if any(not _valid_route(route) for route in (xvb, sinks, standby)):
        return _compat("compute_egress_posture", "standby-route-value", **arguments)
    return _validate_posture(_request("posture", arguments, standby), _route_values())


def _topology_compat(reason, posture, arguments, captured=None):
    del reason
    function = COMPAT_FUNCTIONS["compute_topology"]
    globals_ = dict(function.__globals__)
    globals_["compute_egress_posture"] = lambda **_kwargs: posture
    if captured is not None:
        globals_["_xvb_route"] = lambda *_args: captured["xvb"]
        globals_["_notify_route"] = lambda *_args: captured["sinks"]
        globals_["_xvb_standby_route"] = lambda *_args: captured["standby"]
        globals_["config"] = SimpleNamespace(STRATUM_PORT=captured["port"])
    return _clone(function, globals_)(**arguments)


def compute_topology(
    *,
    firewall,
    p2pool_clearnet,
    xvb_enabled,
    xvb_tor,
    monero_clearnet_sync,
    tari_clearnet_sync,
    monero_route,
    tari_route="local",
    tari_enabled=True,
    healthchecks_enabled,
    telegram_enabled,
    price_feed_enabled=False,
    notify_sinks_enabled=False,
    notify_tor=True,
    notify_sinks_private=False,
    xvb_standby_source="",
    tor_auto_heal=False,
    local_miner_enabled=False,
    tari_explorer=False,
):
    from mining_dashboard.service.network import topology

    arguments = _arguments(locals())
    posture = topology.compute_egress_posture(**arguments)
    if type(local_miner_enabled) is not bool:
        return _topology_compat(
            "boolean-shape", posture, {**arguments, "local_miner_enabled": local_miner_enabled}
        )
    providers = {
        "xvb-route": topology._xvb_route,
        "notify-route": topology._notify_route,
        "standby-route": topology._xvb_standby_route,
        "edge": topology.edge,
        "external-node": topology.ext_node,
    }
    reason = (
        _graph_constant_reason()
        or _constant_reason(topology, "topology")
        or _reason(arguments, providers)
    )
    if reason:
        return _topology_compat(
            reason, posture, {**arguments, "local_miner_enabled": local_miner_enabled}
        )
    xvb = topology._xvb_route(xvb_enabled, xvb_tor)
    sinks = topology._notify_route(notify_sinks_enabled, notify_tor, notify_sinks_private)
    standby = topology._xvb_standby_route(xvb_standby_source)
    captured = {"xvb": xvb, "sinks": sinks, "standby": standby, "port": None}
    if any(not _valid_route(route) for route in (xvb, sinks, standby)):
        captured["port"] = topology.config.STRATUM_PORT
        return _topology_compat(
            "standby-route-value",
            posture,
            {**arguments, "local_miner_enabled": local_miner_enabled},
            captured,
        )
    port = topology.config.STRATUM_PORT
    captured["port"] = port
    if type(port) not in (str, int, bool) or type(port) is int and port.bit_length() > 1000:
        return _topology_compat(
            "stratum-port",
            posture,
            {**arguments, "local_miner_enabled": local_miner_enabled},
            captured,
        )
    stratum_label = f"stratum :{port}"
    if not _utf8_within(stratum_label, 256):
        return _topology_compat(
            "stratum-port",
            posture,
            {**arguments, "local_miner_enabled": local_miner_enabled},
            captured,
        )
    edges = _validate_edges(
        _request(
            "topology-edges",
            arguments,
            standby,
            local_miner_enabled=local_miner_enabled,
            stratum_label=stratum_label,
        ),
        _route_values(),
    )
    nodes = topology.topology_nodes(
        monero_route=monero_route,
        tari_route=tari_route,
        tari_enabled=tari_enabled,
        local_miner_enabled=local_miner_enabled,
    )
    return {"nodes": nodes, "edges": edges, "summary": posture["summary"]}


def topology_nodes(*, monero_route, tari_route, tari_enabled=True, local_miner_enabled=False):
    from mining_dashboard.service.network import topology_graph

    arguments = {
        "monero_route": monero_route,
        "tari_route": tari_route,
        "tari_enabled": tari_enabled,
        "local_miner_enabled": local_miner_enabled,
    }
    if _graph_constant_reason():
        return _compat("topology_nodes", "graph-route-provider", **arguments)
    if (
        type(tari_enabled) is not bool
        or type(local_miner_enabled) is not bool
        or type(monero_route) is not str
        or type(tari_route) is not str
        or monero_route not in _route_values()
        or tari_route not in _route_values()
        or topology_graph.TOPOLOGY_NODES is not PROVIDERS["nodes"]
    ):
        return _compat("topology_nodes", "node-shape", **arguments)
    base = topology_graph.TOPOLOGY_NODES
    if (
        type(base) is not list
        or len(base) > _NATIVE_MAX_NODES
        or any(
            type(node) is not dict
            or any(type(key) is not str for key in node)
            or type(node.get("id")) is not str
            or type(node.get("zone")) is not str
            or not _utf8_within(node["id"], 256)
            or not _utf8_within(node["zone"], 256)
            for node in base
        )
    ):
        return _compat("topology_nodes", "node-provider", **arguments)
    payload = {
        "operation": "topology-nodes",
        "nodes": [{"id": node.get("id"), "zone": node.get("zone")} for node in base],
        **arguments,
    }
    if len(json.dumps(payload).encode()) + 1 > _NATIVE_MAX_REQUEST_BYTES:
        return _compat("topology_nodes", "node-request-size", **arguments)
    plan = go_channel.call("network", payload)
    if type(plan) is not dict or tuple(plan) != ("indices", "relocatable"):
        raise RuntimeError("native network returned invalid nodes")
    indices, relocatable = plan["indices"], plan["relocatable"]
    expected = [
        index
        for index, node in enumerate(base)
        if (local_miner_enabled or node.get("id") != "local-miner")
        and (tari_enabled or node.get("id") != "tari")
    ]
    if type(indices) is not list or indices != expected or type(relocatable) is not list:
        raise RuntimeError("native network returned invalid node selection")
    patches = {}
    for patch in relocatable:
        if (
            type(patch) is not dict
            or set(patch) != {"index", "zone", "remote", "route"}
            or type(patch["index"]) is not int
            or patch["index"] not in expected
            or patch["index"] in patches
            or type(patch["zone"]) is not str
            or type(patch["remote"]) is not bool
            or not _valid_route(patch["route"])
        ):
            raise RuntimeError("native network returned invalid node metadata")
        patches[patch["index"]] = patch
    expected_patches = {index for index in expected if base[index].get("id") in ("monerod", "tari")}
    if set(patches) != expected_patches:
        raise RuntimeError("native network returned incomplete node metadata")
    result = []
    for index in indices:
        if index not in patches:
            result.append(base[index])
            continue
        patch = patches[index]
        result.append(
            {
                **base[index],
                "zone": patch["zone"],
                "remote": patch["remote"],
                "route": patch["route"],
            }
        )
    return result


def install():
    from mining_dashboard.service.network import egress, topology, topology_graph

    PROVIDERS.setdefault("nodes", topology_graph.TOPOLOGY_NODES)
    for name, value in (
        ("xvb-route", egress._xvb_route),
        ("notify-route", egress._notify_route),
        ("standby-route", egress._xvb_standby_route),
        ("edge", topology.edge),
        ("external-node", topology.ext_node),
    ):
        PROVIDERS.setdefault(name, value)
    for prefix, module in (("egress", egress), ("topology", topology)):
        for name in _MODULE_ROUTE_NAMES[prefix]:
            PROVIDERS.setdefault(f"{prefix}:{name}", getattr(module, name))
    for name in _GRAPH_NAMES:
        PROVIDERS.setdefault(f"graph:{name}", getattr(topology_graph, name))
    PROVIDERS.setdefault("graph:NODE_ROUTES", topology_graph.NODE_ROUTES)
    for module, name in (
        (egress, "compute_egress_posture"),
        (topology, "compute_topology"),
        (topology_graph, "topology_nodes"),
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(module, name))
        COMPAT_FUNCTIONS.setdefault(name, _clone(getattr(module, name)))
        setattr(module, name, globals()[name])
    topology.compute_egress_posture = compute_egress_posture
    topology.topology_nodes = topology_nodes
