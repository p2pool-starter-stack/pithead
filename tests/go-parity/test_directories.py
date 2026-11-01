import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/directories_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

FIELDS = (
    "MONERO_DIR",
    "TARI_DIR",
    "P2POOL_DIR",
    "TOR_DATA_DIR",
    "DASHBOARD_DIR",
    "DASHBOARD_DIR_IS_DEFAULT",
    "PROXY_TLS_DIR",
    "CLEARNET_STATE_DIR",
    "CONTROL_DIR",
    "CADDY_LOG_DIR",
    "_data_root",
    "_dash_cfg",
)


class DirectoryParityTests(unittest.TestCase):
    def setUp(self):
        scratch_root = ROOT / ".go-cache/tmp"
        scratch_root.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=scratch_root)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.workdir = self.directory / "stack"
        self.workdir.mkdir()
        self.config = self.directory / "config.json"
        self.calls = self.directory / "calls"
        self.traps = self.directory / "traps"
        self.marker = self.directory / "tool-called"
        self.tools = self.directory / "bin"
        self.tools.mkdir()
        for name in ("jq", "dirname"):
            tool = self.tools / name
            tool.write_text(
                '#!/bin/sh\nprintf "%s\\n" "${0##*/}" >>"$DIRECTORIES_TOOL_MARKER"\nexit 91\n'
            )
            tool.chmod(0o755)

    def environment(self, implementation, *, binary=None, forbid_tools=False, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            DIRECTORIES_PARITY_IMPL=implementation,
            DIRECTORIES_CALL_LOG=str(self.calls),
            DIRECTORIES_TRAP_LOG=str(self.traps),
            DIRECTORIES_TOOL_MARKER=str(self.marker),
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
        )
        if forbid_tools:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
        env.update(extra or {})
        return env

    def invoke(self, implementation, raw, *, binary=None, forbid_tools=False, extra=None):
        self.config.write_bytes(raw)
        self.calls.write_bytes(b"")
        self.traps.write_bytes(b"")
        self.marker.unlink(missing_ok=True)
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.workdir), str(self.config)],
            env=self.environment(
                implementation, binary=binary, forbid_tools=forbid_tools, extra=extra
            ),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed, self.calls.read_bytes(), self.traps.read_bytes()

    def helper(self, raw, *, cwd=None, producer_status=b"0"):
        payload = b"\0".join((str(cwd or self.workdir).encode(), raw, producer_status)) + b"\0"
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-directories"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY)], env=env, input=payload, capture_output=True, check=False, timeout=15
        )

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()

    def state(self, completed):
        values = completed.stdout.split(b"\0")
        self.assertEqual(len(values), 14)
        self.assertEqual((values[0], values[-1]), (b"", b""))
        return tuple(value.decode() for value in values[1:-1])

    def records(self, raw):
        values = raw.split(b"\0")
        self.assertEqual(values[-1], b"")
        values = values[:-1]
        self.assertEqual(len(values) % 13, 0)
        return tuple(
            tuple(value.decode() for value in values[index : index + 13])
            for index in range(0, len(values), 13)
        )

    def compare(self, raw, *, native=False, binary=None, extra=None):
        baseline, baseline_calls, baseline_traps = self.invoke("bash", raw, extra=extra)
        selected, selected_calls, selected_traps = self.invoke(
            "go", raw, binary=binary, forbid_tools=native, extra=extra
        )
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertEqual(selected_calls, baseline_calls)
        self.assertEqual(selected_traps, baseline_traps)
        if native:
            self.assertFalse(self.marker.exists())
        return selected, selected_calls, selected_traps

    def expected_defaults(self):
        data = str(self.workdir / "data")
        return (
            f"{data}/monero",
            f"{data}/tari",
            f"{data}/p2pool",
            f"{data}/tor",
            f"{data}/dashboard",
            "1",
            f"{data}/proxy-tls",
            f"{data}/clearnet-state",
            f"{data}/control",
            f"{data}/caddy-logs",
            data,
            "",
        )

    def test_supported_layouts_match_reference_without_jq_or_dirname(self):
        shared = str(self.directory / "shared")
        cases = [
            ({}, self.expected_defaults()),
            (
                {
                    "monero": {"data_dir": f"{shared}/monero"},
                    "tari": {"data_dir": f"{shared}/tari"},
                    "p2pool": {"data_dir": f"{shared}/p2pool"},
                    "tor": {"data_dir": f"{shared}/tor"},
                },
                (
                    f"{shared}/monero",
                    f"{shared}/tari",
                    f"{shared}/p2pool",
                    f"{shared}/tor",
                    f"{shared}/dashboard",
                    "1",
                    f"{shared}/proxy-tls",
                    str(self.workdir / "data/clearnet-state"),
                    str(self.workdir / "data/control"),
                    str(self.workdir / "data/caddy-logs"),
                    shared,
                    "",
                ),
            ),
            (
                {
                    "monero": {"data_dir": f"{shared}/monero"},
                    "dashboard": {"data_dir": f"{shared}/dash-pinned"},
                },
                (
                    f"{shared}/monero",
                    str(self.workdir / "data/tari"),
                    str(self.workdir / "data/p2pool"),
                    str(self.workdir / "data/tor"),
                    f"{shared}/dash-pinned",
                    "0",
                    str(self.workdir / "data/proxy-tls"),
                    str(self.workdir / "data/clearnet-state"),
                    str(self.workdir / "data/control"),
                    str(self.workdir / "data/caddy-logs"),
                    str(self.workdir / "data"),
                    f"{shared}/dash-pinned",
                ),
            ),
        ]
        for document, expected in cases:
            with self.subTest(document=document):
                completed, calls, traps = self.compare(self.encoded(document), native=True)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(self.state(completed), expected)
                self.assertEqual(len(self.records(calls)), 9)
                self.assertEqual(traps, b"exit:0\0")

    def test_native_derives_then_actual_guards_reject_unsafe_absolute_paths(self):
        cases = ("/srv/pithead/../monero", "/srv/pithead/./monero", "/srv/pithead//monero")
        for path in cases:
            with self.subTest(path=path):
                completed, calls, traps = self.compare(
                    self.encoded({"monero": {"data_dir": path}}), native=True
                )
                self.assertEqual(completed.returncode, 1)
                self.assertEqual(self.records(calls)[0][0], path)
                self.assertEqual(traps, b"exit:1\0")

    def test_trailing_slash_and_forced_guard_failure_preserve_order_and_exit_trap(self):
        trailing = str(self.directory / "shared/monero") + "/"
        completed, calls, _ = self.compare(
            self.encoded({"monero": {"data_dir": trailing}}), native=True
        )
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(self.state(completed)[0], trailing)
        extra = {"DIRECTORIES_FAIL_INDEX": "4", "DIRECTORIES_FAIL_PATH": "/"}
        completed, calls, traps = self.compare(b"{}", native=True, extra=extra)
        self.assertEqual(completed.returncode, 1)
        records = self.records(calls)
        self.assertEqual(len(records), 4)
        self.assertEqual(tuple(record[0] for record in records), self.expected_defaults()[:4])
        self.assertTrue(all(record[1:] == records[0][1:] for record in records))
        self.assertEqual(traps, b"exit:1\0")
        extra = {
            "DIRECTORIES_FAIL_INDEX": "4",
            "DIRECTORIES_RETURN_RC": "9",
            "DIRECTORIES_ERR_TRAP": "1",
        }
        completed, calls, traps = self.compare(b"{}", native=True, extra=extra)
        self.assertEqual(completed.returncode, 9)
        self.assertEqual(len(self.records(calls)), 4)
        self.assertIn(b"err:9\0", traps)
        self.assertTrue(traps.endswith(b"exit:9\0"))

    def test_unsupported_inputs_and_bad_helpers_fall_back_atomically(self):
        unsupported = (
            b'{"monero":{"data_dir":"relative"}}',
            b'{"monero":{"data_dir":"//server/share"}}',
            b'{"monero":{"data_dir":"/srv/a\\nb"}}',
            b'{"monero":{"data_dir":{"nested":true}}}',
            b'{"monero":{"data_dir":"/one","data_dir":"/two"}}',
        )
        for raw in unsupported:
            with self.subTest(raw=raw):
                self.compare(raw)
        scripts = (
            "#!/bin/sh\nexit 125\n",
            "#!/bin/sh\nprintf 'poison\\0short\\0'\n",
            "#!/bin/sh\ni=0; while [ \"$i\" -lt 13 ]; do printf 'poison\\0'; i=$((i+1)); done\n",
        )
        for index, script in enumerate(scripts):
            binary = self.directory / f"fake-helper-{index}"
            binary.write_text(script)
            binary.chmod(0o755)
            with self.subTest(helper=index):
                completed, calls, _ = self.compare(b"{}", binary=binary)
                self.assertEqual(completed.returncode, 0)
                self.assertNotIn(b"poison", completed.stdout + calls)
        self.compare(b"{}", extra={"DIRECTORIES_WITHOUT_GO_HOOK": "1"})

    def test_helper_frame_and_refusals(self):
        completed = self.helper(b"{}")
        self.assertEqual(completed.returncode, 0)
        values = completed.stdout.split(b"\0")
        self.assertEqual(len(values), 13)
        self.assertEqual(values[-1], b"")
        self.assertEqual(tuple(value.decode() for value in values[:-1]), self.expected_defaults())
        for raw, status in (
            (b"{}", b"7"),
            (b'{"monero":{"data_dir":"relative"}}', b"0"),
            (b'{"monero":{"data_dir":"//server/share"}}', b"0"),
            (b'{"monero":{"data_dir":{"nested":true}}}', b"0"),
            (b'{"monero":{"data_dir":"/a","data_dir":"/b"}}', b"0"),
            (b'{"monero":{"data_dir":"/a\\nb"}}', b"0"),
        ):
            with self.subTest(raw=raw, status=status):
                refused = self.helper(raw, producer_status=status)
                self.assertEqual(
                    (refused.returncode, refused.stdout, refused.stderr), (125, b"", b"")
                )


if __name__ == "__main__":
    unittest.main()
