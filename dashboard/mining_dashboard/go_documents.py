import json

from mining_dashboard import go_channel
from mining_dashboard.go_wizard_config import _tree, _value

REFERENCE_FUNCTIONS = {}


def _key(value, identities):
    if isinstance(value, str):
        return {"key": _tree(value, identities)}
    return {"key": ["null", None], "key_json": _tree(json.dumps(value), identities)}


def _node(value, identities, *, pairs_only=False, originals=None):
    from mining_dashboard.config import documents

    if (pairs_only and isinstance(value, documents._ObjectPairs)) or (
        not pairs_only and isinstance(value, dict)
    ):
        pairs = value.items() if isinstance(value, dict) else value
        return {
            "kind": "object",
            "fields": [
                {
                    **_key(key, identities),
                    "value": _node(item, identities, pairs_only=pairs_only, originals=originals),
                }
                for key, item in pairs
            ],
        }
    if isinstance(value, list):
        return {
            "kind": "array",
            "items": [
                _node(item, identities, pairs_only=pairs_only, originals=originals)
                for item in value
            ],
        }
    if originals is not None:
        identity = len(originals) + 1
        originals[identity] = value
        return {"kind": "value", "value": ["null", None], "identity": identity}
    if not isinstance(value, (str, int, float, bool, type(None))):
        return {"kind": "value", "value": ["null", None]}
    return {"kind": "value", "value": _tree(value, identities)}


def _call(operation, *, node=None, path="", key=None, pairs_only=False):
    from mining_dashboard.config import documents

    identities = {}
    originals = {}
    native_path = path
    if operation in ("path", "diagnostic"):
        native_path = str(path) if path else ""
    payload = {
        "operation": operation,
        "path": _tree(native_path, identities),
        "key": ["null", None],
    }
    if operation == "path" or (operation == "diagnostic" and key is not None):
        payload.update(_key(key, identities))
    if node is not None or operation in ("decode", "placeholders", "host"):
        payload["node"] = _node(
            node,
            identities,
            pairs_only=pairs_only,
            originals=originals if operation == "decode" else None,
        )
    result = go_channel.call("documents", payload)
    values = {number: value for number, value in identities.values()}
    fault = result.get("fault")
    if fault:
        message = _value(fault["diagnostic"], values)
        if fault["kind"] == "HostConfigError":
            raise documents.HostConfigError(message)
        if fault["kind"] != "ConfigDocumentError":
            raise RuntimeError("invalid native configuration document error")
        error = documents.ConfigDocumentError.__new__(documents.ConfigDocumentError)
        error.path = _value(fault["path"], values)
        error.key = None if fault["key"] is None else _value(fault["key"], values)
        ValueError.__init__(error, message)
        raise error
    value = _value(result["value"], values) if "value" in result else None
    for alias in result.get("aliases", []):
        path = [_value(segment, values) for segment in alias["path"]]
        if not path:
            value = originals[alias["identity"]]
        else:
            parent = value
            for key in path[:-1]:
                parent = parent[key]
            parent[path[-1]] = originals[alias["identity"]]
    return value


def _path(parent, key):
    return _call("path", path=parent, key=key)


def diagnostic(self):
    return _call("diagnostic", path=self.path, key=self.key)


def _decode(node, path=""):
    return _call("decode", node=node, path=path, pairs_only=True)


def reject_placeholders(node, path=""):
    _call("placeholders", node=node, path=path)


def loads(text):
    from mining_dashboard.config import documents

    return _decode(json.loads(text, object_pairs_hook=documents._ObjectPairs))


def load_config(stream):
    cfg = loads(stream.read())
    reject_placeholders(cfg)
    return cfg


def load_host_config(stream):
    cfg = load_config(stream)
    _call("host", node=cfg)
    return cfg


def install():
    from mining_dashboard.config import documents

    for name in (
        "_path",
        "_decode",
        "reject_placeholders",
        "loads",
        "load_config",
        "load_host_config",
    ):
        REFERENCE_FUNCTIONS.setdefault(name, getattr(documents, name))
        setattr(documents, name, globals()[name])
    REFERENCE_FUNCTIONS.setdefault("diagnostic", documents.ConfigDocumentError.diagnostic)
    documents.ConfigDocumentError.diagnostic = diagnostic
