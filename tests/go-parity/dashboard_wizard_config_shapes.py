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
        PYTHONPATH=str(ROOT / "dashboard"),
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        timeout=40,
        check=False,
    )
    assert result.returncode == 0, result.stderr.decode()
    return result.stdout.splitlines()[-1]


def _paired(script):
    expected = _run(script)
    actual = _run(script, "go")
    assert actual == expected


def test_prepare_config_malformed_config_and_falsey_reference_shapes_match():
    _paired(
        r"""
import json, os
from mining_dashboard import wizard_config
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
def capture(cfg, ref):
    try: return ["value", wizard_config.prepare_config(cfg, ref)]
    except Exception as error: return [type(error).__name__, str(error)]
cases = [(None,{}),([],{}),("",{}),({},None),({},[]),
         ({"xmrig_proxy":{"enabled":False}},"")]
print(json.dumps([capture(*case) for case in cases], separators=(",", ":")))
"""
    )


def test_deep_merge_primitive_list_and_null_shapes_match():
    _paired(
        r"""
import json, os
from mining_dashboard import wizard_config
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
def capture(base, over):
    try: return ["value", wizard_config.deep_merge(base, over)]
    except Exception as error: return [type(error).__name__, str(error)]
cases = [([],{}),(None,{}),({},[]),({},""),({},"x"),({},[1]),
         ([["x",1]],None),(7,{})]
print(json.dumps([capture(*case) for case in cases], separators=(",", ":")))
"""
    )


def test_strip_defaults_primitive_list_and_null_shapes_match():
    _paired(
        r"""
import json, os
from mining_dashboard import wizard_config
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
def capture(cfg, ref):
    try: return ["value", wizard_config.strip_defaults(cfg, ref)]
    except Exception as error: return [type(error).__name__, str(error)]
cases = [(None,None),([],7),("",None),(0,[]),([1],{}),("x",{}),
         ({"a":1},None),({"a":1},[]),({"a":1},["a"]),
         ({"a":{}},[]),({"_hidden":1},None),({"a":1},"abc")]
print(json.dumps([capture(*case) for case in cases], separators=(",", ":")))
"""
    )


def test_machine_name_malformed_container_shapes_match():
    _paired(
        r"""
import json, os
from mining_dashboard import wizard_config
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
def capture(cfg, previous):
    try:
        wizard_config.validate_machine_name(cfg, previous)
        return ["value", None]
    except Exception as error: return [type(error).__name__, str(error)]
cases = [(None,{}),([],{}),("",{}),(0,{}),({"dashboard":[]},{}),
         ({"dashboard":{"host":"auto"}},[]),({"dashboard":{"host":"chosen"}},[])]
print(json.dumps([capture(*case) for case in cases], separators=(",", ":")))
"""
    )


def test_recovery_state_malformed_container_shapes_match():
    _paired(
        r"""
import json, os
from mining_dashboard import wizard_recovery
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
def capture(changes, attempt, disks, mode):
    events = []
    def spool_json(name):
        events.append(["json", name])
        return changes if name == "config-changes.json" else attempt
    def spool_read(name):
        events.append(["read", name])
        return mode
    try: result = ["value", wizard_recovery.recovery_state(spool_json, spool_read, disks)]
    except Exception as error: result = [type(error).__name__, str(error)]
    return [result, events]
cases = [(None,{},[],"auto"),([],{ },[],"auto"),({},None,[1],"auto"),
         ({},[],[],"auto"),({}, {},None,"auto"),({}, {},[1],"auto"),
         ({},{"disk":[],"wipe":"keep"},[{"name":"disk-a"}],"auto"),
         ({"changes":[]},{"disk":None,"wipe":None},[],7)]
print(json.dumps([capture(*case) for case in cases], separators=(",", ":")))
"""
    )
