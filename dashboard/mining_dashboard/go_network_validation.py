_POSTURE_FIELDS = ("components", "summary")
_SUMMARY_FIELDS = (
    "firewall",
    "leaks",
    "blocked_by_firewall",
    "unverified",
    "all_tor",
    "level",
    "label",
)
_CONNECTION_FIELDS = {"to", "route", "chosen_clearnet", "blocked_by_firewall"}
_EDGE_FIELDS = {
    "from",
    "to",
    "route",
    "label",
    "kind",
    "chosen_clearnet",
    "blocked_by_firewall",
    "leak",
}


def utf8_within(value, limit):
    if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
        return False
    return len(value.encode()) <= limit


def validate_posture(value, routes):
    if type(value) is not dict or tuple(value) != _POSTURE_FIELDS:
        raise RuntimeError("native network returned invalid posture")
    components, summary = value["components"], value["summary"]
    if (
        type(components) is not list
        or type(summary) is not dict
        or tuple(summary) != _SUMMARY_FIELDS
    ):
        raise RuntimeError("native network returned invalid posture")
    if (
        type(summary["firewall"]) is not bool
        or any(
            type(summary[field]) is not int or summary[field] < 0
            for field in ("leaks", "blocked_by_firewall", "unverified")
        )
        or type(summary["all_tor"]) is not bool
        or summary["level"] not in ("ok", "warn")
        or type(summary["label"]) is not str
    ):
        raise RuntimeError("native network returned invalid summary")
    for component in components:
        if (
            type(component) is not dict
            or set(component) not in ({"name", "conns"}, {"name", "firewalled", "conns"})
            or type(component["name"]) is not str
            or "firewalled" in component
            and type(component["firewalled"]) is not bool
            or type(component["conns"]) is not list
        ):
            raise RuntimeError("native network returned invalid components")
        for connection in component["conns"]:
            if (
                type(connection) is not dict
                or not {"to", "route"} <= set(connection) <= _CONNECTION_FIELDS
                or type(connection["to"]) is not str
                or type(connection["route"]) is not str
                or connection["route"] not in routes
                or any(
                    type(connection[field]) is not bool
                    for field in set(connection) - {"to", "route"}
                )
            ):
                raise RuntimeError("native network returned invalid connections")
    return value


def validate_edges(edges, routes):
    if type(edges) is not list:
        raise RuntimeError("native network returned invalid edges")
    for link in edges:
        if (
            type(link) is not dict
            or not {"from", "to", "route", "label", "kind"} <= set(link) <= _EDGE_FIELDS
            or any(type(link[field]) is not str for field in ("from", "to", "label", "kind"))
            or type(link["route"]) is not str
            or link["route"] not in routes
            or any(
                type(link[field]) is not bool
                for field in set(link) - {"from", "to", "route", "label", "kind"}
            )
        ):
            raise RuntimeError("native network returned invalid edges")
    return edges
