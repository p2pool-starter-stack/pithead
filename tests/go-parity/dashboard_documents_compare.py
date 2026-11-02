import json
import os
import subprocess
import sys
from pathlib import Path

# ruff: noqa: S101, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, implementation="python"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=40,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.splitlines()[-1])


def _paired(script):
    expected = _run(script)
    actual = _run(script, "go")
    assert actual == expected
    return actual


PREAMBLE = r"""
import io, json, math, os
from mining_dashboard.config import documents
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard import go_documents
    go_documents.install()
def clean(value):
    if isinstance(value, float) and math.isnan(value):
        return ["float", "nan"]
    if isinstance(value, float) and math.isinf(value):
        return ["float", "inf" if value > 0 else "-inf"]
    if isinstance(value, dict):
        return ["dict", [[key, clean(item)] for key, item in value.items()]]
    if isinstance(value, list):
        return ["list", [clean(item) for item in value]]
    return [type(value).__name__, value]
def outcome(call):
    try:
        return ["value", clean(call())]
    except Exception as error:
        result = [type(error).__name__, str(error), clean(list(error.args))]
        if isinstance(error, json.JSONDecodeError):
            result.extend([error.msg, error.doc, error.pos, error.lineno, error.colno])
        if isinstance(error, documents.ConfigDocumentError):
            result.extend([error.path, error.key, error.diagnostic()])
        return result
"""


def test_decode_precedence_escapes_and_primitives_match():
    result = _paired(
        PREAMBLE
        + r"""
cases = [
    '{"outer":{"bad":1,"bad":2},"later":0,"later":1}',
    '{"outer":{"ok":1},"later":0,"later":{"bad":1,"bad":2}}',
    '{"first":0,"first":{"bad":1,"bad":2}}',
    '{"first":0,"first":1,',
    '[null,true,false,0,-2,1.25,1e400,"text",{"x":1}]',
    'NaN', 'Infinity', '-Infinity', '42', '"plain"',
    '{"quote\\\"slash\\\\line\\n雪":1,"bad\\ud800":2}',
]
values = [outcome(lambda text=text: documents.loads(text)) for text in cases]
paths = [
    outcome(lambda key=key: documents._path("parent", key))
    for key in ('bad\nkey', 'a"b', 'a\\b', '雪', '\ud800')
]
print(json.dumps([values, paths], ensure_ascii=True, separators=(",",":")))
"""
    )
    assert result[0][0][0] == "ConfigDocumentError"
    assert result[0][1][0] == "ConfigDocumentError"
    assert result[0][2][0] == "ConfigDocumentError"
    assert result[0][3][0] == "JSONDecodeError"
    assert result[0][4][0] == "value"
    assert result[1][0][1][1] == "parent.bad\\nkey"


def test_placeholders_unicode_expansion_and_identity_match():
    result = _paired(
        PREAMBLE
        + r"""
values = [
    {"value":"pa\ufb05e_secret"},
    {"value":"pa\ufb06e_secret"},
    {"value":"your_secret"},
    {"value":"prefix_YOUR_secret"},
    {"value":1, "nested":[None, False]},
]
outcomes = [outcome(lambda value=value: documents.reject_placeholders(value)) for value in values]
outcomes.append(outcome(lambda: documents.reject_placeholders({"leaf":"YOUR_secret"}, "root")))
identity = [
    documents.reject_placeholders(values[-1]) is None,
    values[-1] == {"value":1, "nested":[None, False]},
]
print(json.dumps([outcomes, identity], ensure_ascii=True, separators=(",",":")))
"""
    )
    assert result[0][0][0] == "ConfigDocumentError"
    assert result[0][1][0] == "ConfigDocumentError"
    assert result[0][3][0] == "value"
    assert "root.leaf" in result[0][-1][1]
    assert result[1] == [True, True]


def test_load_config_host_sentinel_and_stream_errors_match():
    result = _paired(
        PREAMBLE
        + r"""
class Broken:
    def read(self):
        raise OSError(5, "fixture read failure")
cases = [
    (documents.load_config, io.StringIO('{"a":[1,"ok"]}')),
    (documents.load_config, io.StringIO('{"a":"YOUR_secret"}')),
    (documents.load_config, io.StringIO('{"a":')),
    (documents.load_config, Broken()),
    (documents.load_host_config, io.StringIO('{"value":1}')),
    (documents.load_host_config, io.StringIO('{"_config_document_error":"curated"}')),
    (documents.load_host_config, io.StringIO('{"_config_document_error":7}')),
    (documents.load_host_config, Broken()),
]
print(json.dumps([outcome(lambda fn=fn, stream=stream: fn(stream)) for fn, stream in cases],
                 ensure_ascii=True, separators=(",",":")))
"""
    )
    assert result[0][0] == "value"
    assert result[1][0] == "ConfigDocumentError"
    assert result[2][0] == "JSONDecodeError"
    assert result[3][0] == "OSError"
    assert result[5][:2] == ["HostConfigError", "curated"]
    assert result[6][:2] == ["HostConfigError", "Invalid host configuration"]


def test_decode_internal_nodes_and_exception_diagnostics_match():
    result = _paired(
        PREAMBLE
        + r"""
plain = {"kept": []}
pairs = documents._ObjectPairs([
    ("a", documents._ObjectPairs([("b", 1)])),
    ("list", [documents._ObjectPairs([("x", 2)])]),
    ("plain", plain),
])
duplicate = documents._ObjectPairs([("x", 1), ("x", 2)])
pair_result = documents._decode(pairs)
plain_result = documents._decode(plain)
plain_list = [plain]
list_result = documents._decode(plain_list)
error = documents.ConfigDocumentError('parent', 'bad\nkey')
print(json.dumps([
    outcome(lambda: pair_result),
    outcome(lambda: documents._decode(duplicate, "root")),
    [pair_result["plain"] is plain, pair_result["plain"]["kept"] is plain["kept"]],
    [plain_result is plain, plain_result["kept"] is plain["kept"]],
    [list_result is plain_list, list_result[0] is plain, list_result[0]["kept"] is plain["kept"]],
    [error.path, error.key, str(error), error.diagnostic()],
], ensure_ascii=True, separators=(",",":")))
"""
    )
    assert result[0][0] == "value"
    assert result[1][0] == "ConfigDocumentError"
    assert result[2] == [True, True]
    assert result[3] == [True, True]
    assert result[4] == [False, True, True]
    assert result[5][2] == result[5][3]


def test_nonstring_private_paths_diagnostics_and_placeholder_keys_match():
    result = _paired(
        PREAMBLE
        + r"""
def defect(path, key):
    try:
        error = documents.ConfigDocumentError(path, key)
        return ["value", error.path, error.key, str(error), error.diagnostic()]
    except Exception as error:
        return outcome(lambda: (_ for _ in ()).throw(error))
paths = [
    outcome(lambda parent=parent, key=key: documents._path(parent, key))
    for parent, key in [
        (0, "key"), (None, "key"), (7, "key"), ([1], "key"),
        ("", 1), ("", True), ("", False), ("", None), ("", 1.25),
        ("", (1, "x")), ("", [1, "x"]), ("", {"a":1}),
        ("root", 1), ("root", (1, "x")),
    ]
]
defects = [
    defect(0, 1), defect(["parent"], True), defect(7, [1, "x"]),
    defect({"parent":1}, {"key":2}), defect(["placeholder"], None),
]
placeholder_keys = [
    outcome(lambda value=value: documents.reject_placeholders(value))
    for value in ({1:"YOUR_secret"}, {None:"YOUR_secret"}, {(1,"x"):"YOUR_secret"})
]
print(json.dumps([paths, defects, placeholder_keys], ensure_ascii=True, separators=(",",":")))
"""
    )
    assert [case[1][1] for case in result[0][:4]] == ["key", "key", "7.key", "[1].key"]
    assert [case[1][1] for case in result[0][4:9]] == ["", "ru", "als", "ul", ".2"]
    assert result[1][0][3] == "duplicate key 1 at the top level (path )"
    assert result[2][0][1] == "placeholder value at the top level"
    assert result[2][1][1] == "placeholder value at ul"
    assert result[2][2][1] == 'placeholder value at 1, "x"'
