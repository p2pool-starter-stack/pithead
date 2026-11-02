import json
import os
import subprocess
import sys
from pathlib import Path

# ruff: noqa: S101, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, directory, implementation="python"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        WIZARD_SPOOL=str(directory / "spool"),
        WIZARD_RESTORE=str(directory / "restore"),
        WIZARD_HANDOFF=str(directory / "handoff"),
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


def _paired(tmp_path, script):
    expected = _run(script, tmp_path / "reference")
    actual = _run(script, tmp_path / "native", "go")
    assert actual == expected
    return actual


PREAMBLE = r"""
import json, math, os
from pathlib import Path
from mining_dashboard.wizard import defaults, server
from mining_dashboard import wizard_recovery
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard import go_wizard_values
    go_wizard_values.install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
spool.mkdir(parents=True)
def outcome(call):
    try:
        return ["value", call()]
    except Exception as error:
        return [type(error).__name__, str(error)]
"""


def test_tari_defaults_and_new_answers_match(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
disks = [
    {"name":"same","state":"empty"},
    {"name":"same","state":"pithead-with-data"},
]
cases = [
    ({"tari_chain_held":True}, [], "", "keep"),
    ({"tari_chain_held":1}, [], "", "keep"),
    ({"tari_chain_held":"true"}, [], "", "keep"),
    ({}, disks, "same", "data"),
    ({}, list(reversed(disks)), "same", "data"),
    ({}, disks, "missing", "data"),
]
values = [outcome(lambda c=c: defaults.tari_disk_default(*c)) for c in cases]
answers = [outcome(lambda p=p: defaults.new_machine_answers({}, [], p))
           for p in ("diy", "appliance", "unknown")]
print(json.dumps([values, answers], ensure_ascii=True, separators=(",",":")))
""",
    )
    assert result[0][0] == ["value", "local"]
    assert result[0][1][1] == "off"
    assert result[0][3][1] == "off"
    assert result[0][4][1] == "local"
    assert result[1][-1][0] == "ValueError"


def test_explicit_materialization_aliases_and_input_ownership_match(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
marker = float("nan")
shared = {"nested":[marker]}
cfg = {
    "tari":{"mode":"off","clearnet_initial_sync":marker},
    "monero":{"clearnet_initial_sync":marker},
    "dashboard":{"host":shared,"tari_required":False},
    "xvb":{"enabled":True},
    "local_miner":{"enabled":False},
}
ref = {
    "tari":{"mode":"off","clearnet_initial_sync":False},
    "monero":{"clearnet_initial_sync":False},
    "dashboard":{"host":"auto","tari_required":False},
    "xvb":{"enabled":True},
    "local_miner":{"enabled":False},
}
before = list(cfg)
value = defaults.explicit_wizard_config(cfg, ref)
checks = [
    value["dashboard"]["host"] is shared,
    value["tari"]["clearnet_initial_sync"] is marker,
    value["monero"]["clearnet_initial_sync"] is marker,
    value["tari"]["clearnet_initial_sync"] is value["monero"]["clearnet_initial_sync"],
    list(cfg) == before,
]
print(json.dumps([checks, sorted(value), sorted(value["dashboard"])], separators=(",",":")))
""",
    )
    assert all(result[0])


def test_remember_changes_normalization_deduplication_and_order_match(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
events = []
state = {"config-changes.json":{"changes":["α","old"]}}
def read(name):
    events.append(["read", name])
    return state.get(name, {})
def write(name, text):
    events.append(["write", name, json.loads(text)])
    state[name] = json.loads(text)
wizard_recovery.remember_changes(str(spool), ["α","雪"], read, write)
state["config-changes.json"] = {"changes":[float("nan")]}
wizard_recovery.remember_changes(str(spool), ["fresh"], read, write)
state["config-changes.json"] = {"changes":[]}
wizard_recovery.remember_changes(str(spool), [True, 1, False, 0], read, write)
spool.joinpath("config-changes.json").write_text("fixture")
state["config-changes.json"] = {"changes":[]}
wizard_recovery.remember_changes(str(spool), [], read, write)
print(json.dumps([events, spool.joinpath("config-changes.json").exists()],
                 ensure_ascii=True, separators=(",",":")))
""",
    )
    writes = [event[2] for event in result[0] if event[0] == "write"]
    assert writes[2]["changes"] == [True, False]
    assert result[1] is False


def test_disk_inventory_unicode_digits_errors_and_large_integers_match(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
huge = "9" * 180
cases = [
    "disk\t1T\t模型\t雪\tempty\t١٢٣\t" + huge,
    "short\trow",
    "bad\t1T\tm\ts\tempty\t²",
    "bad-available\t1T\tm\ts\tempty\t12\t²",
]
print(json.dumps([outcome(lambda raw=raw: defaults.disk_inventory(raw)) for raw in cases],
                 ensure_ascii=True, separators=(",",":")))
""",
    )
    assert result[0][1][0]["data_bytes"] == 123
    assert len(str(result[0][1][0]["data_available_bytes"])) == 180
    assert result[2][0] == "ValueError"
    assert result[3][0] == "ValueError"


def test_remove_spool_files_links_and_partial_failure_match(tmp_path):
    result = _paired(
        tmp_path,
        PREAMBLE
        + r"""
spool.joinpath("first").write_text("1")
spool.joinpath("second").write_text("2")
spool.joinpath("broken").symlink_to(spool / "absent")
wizard_recovery.remove_spool(str(spool), "missing", "broken", "first")
normal = sorted(path.name for path in spool.iterdir())
spool.joinpath("first").write_text("1")
real_unlink = os.unlink
seen = []
def fail_second(path):
    seen.append(Path(path).name)
    if Path(path).name == "second":
        raise OSError(5, "fixture unlink failure")
    real_unlink(path)
os.unlink = fail_second
if os.environ["PITHEAD_IMPL"] == "go":
    from dashboard_wizard_values_io import run
    from mining_dashboard import go_wizard_values
    go_wizard_values._remove = lambda directory, names: run({
        "operation":"remove-spool", "spool":directory, "names":list(names),
        "io_hooks":{"unlink":True},
    })
error = outcome(lambda: wizard_recovery.remove_spool(str(spool), "first", "second"))
os.unlink = real_unlink
print(json.dumps([normal, seen, error, sorted(path.name for path in spool.iterdir())],
                 separators=(",",":")))
""",
    )
    assert result[0] == ["broken", "second"]
    assert result[1] == ["first", "second"]
    assert result[2][0] == "OSError"
    assert result[3] == ["broken", "second"]
