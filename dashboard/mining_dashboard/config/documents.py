"""Raw config document checks, before JSON normalization or secret masking."""

import json


class _ObjectPairs(list):
    """Keep object members until their paths and duplicate keys have been checked."""


def _path(parent, key):
    key = json.dumps(key, ensure_ascii=True)[1:-1].replace('\\"', '"')
    return f"{parent}.{key}" if parent else key


def _decode(node, path=""):
    if isinstance(node, _ObjectPairs):
        result = {}
        for key, value in node:
            if key in result:
                location = path or "the top level"
                raise ValueError(
                    f"duplicate key {json.dumps(key)} at {location} (path {_path(path, key)})"
                )
            result[key] = _decode(value, _path(path, key))
        return result
    if isinstance(node, list):
        return [_decode(value, f"{path}[{index}]") for index, value in enumerate(node)]
    return node


def reject_placeholders(node, path=""):
    """Reject template instructions in every string leaf; never print its value."""
    if isinstance(node, dict):
        for key, value in node.items():
            reject_placeholders(value, _path(path, key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            reject_placeholders(value, f"{path}[{index}]")
    elif isinstance(node, str) and node.upper().startswith(("PASTE_", "YOUR_")):
        raise ValueError(f"placeholder value at {path or 'the top level'}")


def loads(text):
    """Decode JSON without silently replacing any repeated object member."""
    return _decode(json.loads(text, object_pairs_hook=_ObjectPairs))


def load_config(stream):
    """Read and validate a host config before secret masking can hide placeholders."""
    cfg = loads(stream.read())
    reject_placeholders(cfg)
    return cfg


class HostConfigError(ValueError):
    """The host refused the raw source before rendering its masked copy."""


def load_host_config(stream):
    """Refuse the renderer's path-only error record before merging defaults or masking."""
    cfg = load_config(stream)
    if isinstance(cfg, dict) and "_config_document_error" in cfg:
        reason = cfg["_config_document_error"]
        raise HostConfigError(reason if isinstance(reason, str) else "Invalid host configuration")
    return cfg
