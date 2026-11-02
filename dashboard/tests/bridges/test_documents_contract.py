import io
import json

import pytest

from mining_dashboard import go_documents
from mining_dashboard.config import documents


def test_node_projection_preserves_shapes_and_opaque_identities():
    identities = {}
    originals = {}
    opaque = object()
    node = go_documents._node({"items": [1, opaque]}, identities, originals=originals)
    assert node["kind"] == "object"
    assert node["fields"][0]["value"]["items"][1]["identity"] == 2
    assert originals == {1: 1, 2: opaque}

    pairs = documents._ObjectPairs([("a", 1), ("a", 2)])
    projected = go_documents._node(pairs, {}, pairs_only=True)
    assert [field["key"] for field in projected["fields"]] == [
        ["str", "a"],
        ["str", "a"],
    ]
    assert go_documents._key((1, "x"), {})["key"] == ["null", None]


def test_call_builds_paths_and_restores_alias_identity(monkeypatch):
    calls = []
    opaque = {"kept": []}

    def call(helper, payload):
        calls.append((helper, payload))
        if payload["operation"] == "path":
            return {"value": ["str", "root.key"]}
        return {
            "value": ["list", [["null", None]]],
            "aliases": [{"path": [["int", "0"]], "identity": 1}],
        }

    monkeypatch.setattr(go_documents.go_channel, "call", call)
    assert go_documents._path("root", "key") == "root.key"
    assert calls[0] == (
        "documents",
        {
            "operation": "path",
            "path": ["str", "root"],
            "key": ["str", "key"],
        },
    )
    decoded = go_documents._decode(opaque)
    assert decoded[0] is opaque
    assert calls[1][1]["node"]["identity"] == 1


@pytest.mark.parametrize(
    ("kind", "exception"),
    [
        ("ConfigDocumentError", documents.ConfigDocumentError),
        ("HostConfigError", documents.HostConfigError),
    ],
)
def test_call_recreates_document_faults(monkeypatch, kind, exception):
    monkeypatch.setattr(
        go_documents.go_channel,
        "call",
        lambda *_: {
            "fault": {
                "kind": kind,
                "diagnostic": ["str", "bad value"],
                "path": ["str", "root"],
                "key": ["str", "leaf"],
            }
        },
    )
    with pytest.raises(exception, match="bad value") as caught:
        go_documents.reject_placeholders({"leaf": "bad"})
    if kind == "ConfigDocumentError":
        assert caught.value.path == "root"
        assert caught.value.key == "leaf"


def test_call_rejects_unknown_fault_and_propagates_transport(monkeypatch):
    monkeypatch.setattr(
        go_documents.go_channel,
        "call",
        lambda *_: {
            "fault": {
                "kind": "OtherError",
                "diagnostic": ["str", "bad"],
                "path": ["str", ""],
                "key": None,
            }
        },
    )
    with pytest.raises(RuntimeError, match="invalid native"):
        go_documents._call("host", node={})

    def broken(*_):
        raise RuntimeError("transport failed")

    monkeypatch.setattr(go_documents.go_channel, "call", broken)
    with pytest.raises(RuntimeError, match="transport failed"):
        go_documents._path("", "x")


def test_load_wrappers_preserve_callback_order(monkeypatch):
    events = []

    def loads(text):
        events.append(("loads", text))
        return {"value": 1}

    def reject(cfg):
        events.append(("reject", cfg))

    def call(operation, **values):
        events.append((operation, values))

    monkeypatch.setattr(go_documents, "loads", loads)
    monkeypatch.setattr(go_documents, "reject_placeholders", reject)
    monkeypatch.setattr(go_documents, "_call", call)
    stream = io.StringIO('{"value":1}')
    assert go_documents.load_host_config(stream) == {"value": 1}
    assert events == [
        ("loads", '{"value":1}'),
        ("reject", {"value": 1}),
        ("host", {"node": {"value": 1}}),
    ]


def test_loads_and_diagnostic_use_native_contract(monkeypatch):
    calls = []

    def call(operation, **values):
        calls.append((operation, values))
        if operation == "decode":
            return {"decoded": True}
        return "duplicate key"

    monkeypatch.setattr(go_documents, "_call", call)
    assert go_documents.loads('{"a":1}') == {"decoded": True}
    assert isinstance(calls[0][1]["node"], documents._ObjectPairs)
    error = documents.ConfigDocumentError("root", "a")
    assert go_documents.diagnostic(error) == "duplicate key"


def test_install_replaces_document_entrypoints(monkeypatch):
    monkeypatch.setattr(go_documents, "REFERENCE_FUNCTIONS", {})
    names = (
        "_path",
        "_decode",
        "reject_placeholders",
        "loads",
        "load_config",
        "load_host_config",
    )
    originals = {name: getattr(documents, name) for name in names}
    diagnostic = documents.ConfigDocumentError.diagnostic
    for name, value in originals.items():
        monkeypatch.setattr(documents, name, value)
    monkeypatch.setattr(documents.ConfigDocumentError, "diagnostic", diagnostic)

    go_documents.install()

    assert all(getattr(documents, name) is getattr(go_documents, name) for name in names)
    assert documents.ConfigDocumentError.diagnostic is go_documents.diagnostic
    assert go_documents.REFERENCE_FUNCTIONS == {**originals, "diagnostic": diagnostic}


def test_call_rejects_malformed_native_value(monkeypatch):
    monkeypatch.setattr(
        go_documents.go_channel,
        "call",
        lambda *_: {"value": ["unknown", None]},
    )
    with pytest.raises(RuntimeError, match="invalid value"):
        go_documents._path("", "key")


def test_nonstring_key_projection_is_json_stable():
    projected = go_documents._key({"b": [1, True]}, {})
    assert projected["key_json"] == ["str", json.dumps({"b": [1, True]})]
