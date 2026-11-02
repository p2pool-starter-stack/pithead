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
    return actual


def test_prepare_config_migrations_conflicts_filters_and_input_ownership_match():
    _paired(
        r"""
import copy, json, os
from mining_dashboard import wizard_config
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
ref = {
    "xvb":{"enabled":True,"url":"","donor_id":""},
    "dashboard":{"workers":[]},
    "workers":{"list":[]},
    "monero":{"wallet_address":""},
}
cases = [
    ({"config_version":"1.0","xmrig_proxy":{"enabled":False,"url":"chosen"},
      "dashboard":{"workers":[{"name":"shed","host":"rig.example.com",
                                "api_token":"secret"}]},
      "unknown":{"credential":"hidden"}}, False),
    ({"xvb":{"enabled":True},"xmrig_proxy":{"enabled":False}}, True),
    ({"xvb":{"enabled":False},"xmrig_proxy":{"enabled":1}}, True),
    ({"xvb":{"enabled":False,"url":"chosen","donor_id":"mine"},
      "xmrig_proxy":{"enabled":True,"url":wizard_config._XVB_ALIAS_V1_DEFAULTS["url"],
                     "donor_id":"auto"}}, True),
    ({"dashboard":{"workers":{}},"workers":{"list":[]}}, False),
]
out = []
for cfg, strict in cases:
    before = copy.deepcopy(cfg)
    try:
        value = wizard_config.prepare_config(cfg, ref, reject_legacy_conflicts=strict)
        result = ["value", value]
    except Exception as error:
        result = [type(error).__name__, str(error)]
    out.append([result, cfg == before])
print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
"""
    )


def test_merge_and_default_stripping_numeric_and_nonfinite_values_match():
    _paired(
        r"""
import copy, json, math, os
from mining_dashboard import wizard_config
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
def describe(value):
    if isinstance(value, dict):
        return ["dict", [[key, describe(item)] for key, item in value.items()]]
    if isinstance(value, list):
        return ["list", [describe(item) for item in value]]
    if isinstance(value, float):
        if math.isnan(value): return ["float", "nan"]
        if math.isinf(value): return ["float", "inf" if value > 0 else "-inf"]
        return ["float", repr(value)]
    return [type(value).__name__, value]
base = {"same":{"flag":True,"count":1,"nested":{"old":-float("inf")}},
        "values":[float("nan"),float("inf"),1.0]}
over = {"same":{"count":2.0,"nested":{"new":float("nan")}},"extra":False}
cfg = {"bool":True,"integer":1,"real":1.0,"nan":float("nan"),
       "nested":{"positive":float("inf"),"negative":-float("inf"),"drop":1}}
ref = {"bool":1,"integer":1.0,"real":True,"nan":float("nan"),
       "nested":{"positive":float("inf"),"negative":float("inf"),"drop":True}}
snapshots = [describe(base), describe(over), describe(cfg), describe(ref)]
result = [describe(wizard_config.deep_merge(base, over)),
          describe(wizard_config.strip_defaults(cfg, ref)),
          snapshots == [describe(base), describe(over), describe(cfg), describe(ref)]]
print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
"""
    )


def test_machine_name_bounds_and_legacy_identity_match():
    _paired(
        r"""
import json, os
from mining_dashboard import wizard_config
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
cases = [
    ({}, {}),
    ({"dashboard":{"host":"auto"}}, {}),
    ({"dashboard":{"host":"a"}}, {}),
    ({"dashboard":{"host":"a" * 63}}, {}),
    ({"dashboard":{"host":""}}, {}),
    ({"dashboard":{"host":"a" * 64}}, {}),
    ({"dashboard":{"host":"-bad"}}, {}),
    ({"dashboard":{"host":"rig.example.com"}}, {}),
    ({"dashboard":{"host":"rig.example.com"}},
     {"dashboard":{"host":"rig.example.com"}}),
    ({"dashboard":{"host":"2001:db8::1"}},
     {"dashboard":{"host":"2001:db8::1"}}),
    ({"dashboard":[]}, {}),
]
out = []
for cfg, previous in cases:
    try:
        wizard_config.validate_machine_name(cfg, previous)
        out.append(["value", None])
    except Exception as error:
        out.append([type(error).__name__, str(error)])
print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
"""
    )


def test_known_config_lone_surrogate_keys_and_values_match():
    _paired(
        r"""
import json, os
from mining_dashboard import wizard_config
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
surrogate = "\ud800"
cfg = {surrogate:{"value":surrogate},"block":{"value":surrogate},"gone" + surrogate:surrogate}
ref = {surrogate:{"value":""},"block":{"value":""}}
prepared = wizard_config.prepare_config(cfg, ref)
merged = wizard_config.deep_merge({surrogate:{"old":surrogate}}, {surrogate:{"new":surrogate}})
stripped = wizard_config.strip_defaults(cfg, ref)
print(json.dumps([prepared, merged, stripped], ensure_ascii=True, separators=(",", ":")))
"""
    )


def test_recovery_state_disk_and_mode_validation_match():
    _paired(
        r"""
import json, os
from mining_dashboard import wizard_recovery
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_config import install
    install(server)
cases = [
    ({"changes":["first","second","\ud800"]},{"disk":"disk-a","wipe":"data"},"set",
     [{"name":"disk-a"},{"name":"disk-b"}]),
    ({"changes":["first",7]},{"disk":"disk-a","wipe":"all"},"invalid",
     [{"name":"disk-a"}]),
    ({"changes":"wrong"},{"disk":"removed","wipe":"keep"},"none",
     [{"name":"replacement"}]),
    ({},{"disk":"disk-a","wipe":"erase"},"",[{"name":"disk-a"}]),
]
out = []
for changes, attempt, mode, disks in cases:
    def spool_json(name):
        return changes if name == "config-changes.json" else attempt
    def spool_read(name):
        assert name == "auth-mode"
        return mode
    out.append(wizard_recovery.recovery_state(spool_json, spool_read, disks))
print(json.dumps(out, ensure_ascii=True, separators=(",", ":")))
"""
    )
