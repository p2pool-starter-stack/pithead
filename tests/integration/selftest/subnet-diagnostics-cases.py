"""Diagnostics contracts with hostile wire data and bounded local child processes."""

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

SPEC = importlib.util.spec_from_file_location(
    "diagnostics", Path(__file__).resolve().parents[1] / "subnet-diagnostics.py"
)
d = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(d)

PRIVATE_FIXTURE = "fixture-sensitive-host-cookie-password"
INFO = {
    "status": "OK",
    "restricted": False,
    "height": 100,
    "target_height": 183,
    "synchronized": False,
    "outgoing_connections_count": 0,
    "incoming_connections_count": 0,
    "white_peerlist_size": 4,
    "grey_peerlist_size": 5,
    "password": PRIVATE_FIXTURE,
    "address": "198.51.100.3",
    "cookie": "f" * 64,
}


class Diagnostics(unittest.TestCase):
    def test_admin_zero_is_a_real_reading_only_when_unrestricted(self):
        self.assertEqual(d.monero_info(json.dumps(INFO))["outgoing_connections_count"], 0)
        for flag in (True, None, "false", 0):
            out = d.monero_info(json.dumps({**INFO, "restricted": flag}))
            self.assertNotIn("outgoing_connections_count", out)
            self.assertEqual(out["rpc_visibility"], "unverified")
        for body in ({"status": "BUSY"}, {"error": {"message": PRIVATE_FIXTURE}}):
            with self.assertRaises(ValueError):
                d.monero_info(json.dumps(body))

    def test_transfers_keep_numbers_not_peer_identities(self):
        peer = {
            "height": 183,
            "recv_count": 42,
            "current_download": 2.5,
            "incoming": False,
            "address": PRIVATE_FIXTURE,
            "peer_id": PRIVATE_FIXTURE,
            "state": PRIVATE_FIXTURE,
            "send_count": PRIVATE_FIXTURE,
        }
        out = d.monero_transfer(
            json.dumps({"result": {"status": "OK", "connections": [peer] * 65}}), "get_connections"
        )
        self.assertEqual(out["peer_count"], 65)
        self.assertEqual(len(out["peers"]), 64)
        self.assertTrue(out["peers_clipped"])
        self.assertEqual(out["peers"][0]["recv_count"], 42)
        self.assertNotIn(PRIVATE_FIXTURE, json.dumps(out))
        out = d.monero_transfer(
            json.dumps(
                {
                    "result": {
                        "status": "OK",
                        "height": 100,
                        "peers": [{"info": peer}],
                        "spans": [
                            {
                                "start_block_height": 101,
                                "nblocks": 10,
                                "size": 8000,
                                "connection_id": PRIVATE_FIXTURE,
                            }
                        ],
                    }
                }
            ),
            "sync_info",
        )
        self.assertEqual(out["spans"][0]["nblocks"], 10)
        self.assertNotIn(PRIVATE_FIXTURE, json.dumps(out))
        with self.assertRaises(ValueError):
            d.monero_transfer('{"result":{"status":"OK","restricted":true}}', "sync_info")

    def test_tor_control_auth_framing_and_empty_populations(self):
        for field in ("circuit-status", "stream-status"):
            self.assertEqual(
                d.tor_control(
                    f"250 OK\r\n250-{field}=\r\n250 OK\r\n250 closing connection\r\n", field
                )["total"],
                0,
            )
            for bad in (
                f"515 {PRIVATE_FIXTURE}\n",
                f"250 OK\n552 {PRIVATE_FIXTURE}\n250 closing connection\n",
                f"250 OK\n250+{field}=\n.\n",
            ):
                with self.assertRaises(ValueError):
                    d.tor_control(bad, field)
        raw = f'250 OK\n250+circuit-status=\n17 BUILT ${PRIVATE_FIXTURE} SOCKS_PASSWORD="{PRIVATE_FIXTURE}"\n18 LAUNCHED\n.\n250 OK\n250 closing connection\n'
        self.assertEqual(
            d.tor_control(raw, "circuit-status")["states"], {"BUILT": 1, "LAUNCHED": 1}
        )
        raw = f"250 OK\n250+stream-status=\n19 SENTCONNECT 17 {PRIVATE_FIXTURE}:80 SOURCE_ADDR={PRIVATE_FIXTURE}\n.\n250 OK\n250 closing connection\n"
        self.assertNotIn(PRIVATE_FIXTURE, json.dumps(d.tor_control(raw, "stream-status")))

    def test_history_missing_does_not_mean_zero(self):
        raw = f"TotalBuildTimes 1000\nCircuitBuildAbandonedCount 1000\nCircuitBuildTimeBin 123 5\nGuard {PRIVATE_FIXTURE}\n"
        out = d.tor_history(raw)
        self.assertEqual(out["CircuitBuildAbandonedCount"], 1000)
        self.assertEqual(out["bin_samples"], 5)
        self.assertNotIn(PRIVATE_FIXTURE, json.dumps(out))
        for raw in (
            "",
            "TotalBuildTimes 1000\n",
            "TotalBuildTimes 1\nTotalBuildTimes 2\nCircuitBuildAbandonedCount 0\n",
        ):
            with self.assertRaises(ValueError):
                d.tor_history(raw)

    def test_container_has_stable_opaque_identity_and_no_topology(self):
        obj = {
            "Id": "a" * 64,
            "State": {
                "Status": "exited",
                "StartedAt": "2026-10-14T12:00:00Z",
                "ExitCode": 0,
                "OOMKilled": False,
                "Health": {"Status": "unhealthy", "Log": [PRIVATE_FIXTURE]},
            },
            "RestartCount": 0,
            "NetworkSettings": {"Networks": {"mining_net": {"IPAddress": "198.51.100.3"}}},
            "Mounts": [PRIVATE_FIXTURE],
            "Config": {"Env": [PRIVATE_FIXTURE]},
        }
        out = d.container(json.dumps([obj]), "198.51.100.3")
        self.assertTrue(out["address_matches_render"])
        self.assertEqual(out["identity"], d.container(json.dumps([obj]), "")["identity"])
        self.assertNotIn("a" * 64, json.dumps(out))
        self.assertNotIn(PRIVATE_FIXTURE, json.dumps(out))
        self.assertNotIn("198.51.100.3", json.dumps(out))

    def test_missing_numeric_fields_and_transfer_arrays_are_not_empty_readings(self):
        for missing in ("height", "target_height", "outgoing_connections_count"):
            obj = dict(INFO)
            obj.pop(missing)
            with self.assertRaises(ValueError):
                d.monero_info(json.dumps(obj))
        for method in ("get_connections", "sync_info"):
            for obj in (
                {"status": "OK"},
                {"status": "OK", "connections": None, "peers": None, "spans": []},
                {"status": "OK", "connections": [{}], "peers": [{}], "spans": []},
                {"status": "OK", "connections": [None], "peers": [None], "spans": []},
            ):
                with self.assertRaises((KeyError, ValueError)):
                    d.monero_transfer(json.dumps({"result": obj}), method)

    def test_hostile_timestamps_are_excluded_and_dynamic_addresses_are_not_mismatches(self):
        for stamp in (
            "2026-10-14T198.51.100.3Z",
            "2026-99-99T99:99:99Z",
            PRIVATE_FIXTURE,
            "2026-10-14T12:00:00.123456789123Z",
        ):
            obj = {
                "Id": "a" * 64,
                "State": {"StartedAt": stamp},
                "NetworkSettings": {"Networks": {"mining_net": {"IPAddress": "198.51.100.8"}}},
            }
            result = io.StringIO()
            with (
                contextlib.redirect_stdout(result),
                patch.object(d, "run", return_value=({"exit_code": 0}, json.dumps([obj]))),
            ):
                d.sample("container", ["fixed"], lambda raw: d.container(raw, ""))
            self.assertNotIn(stamp, result.getvalue())
        obj = {
            "Id": "a" * 64,
            "State": {},
            "NetworkSettings": {"Networks": {"mining_net": {"IPAddress": "198.51.100.8"}}},
        }
        out = d.container(json.dumps([obj]), "")
        self.assertTrue(out["mining_network_present"])
        self.assertNotIn("address_matches_render", out)
        obj["NetworkSettings"]["Networks"]["mining_net"]["IPAddress"] = "198.51.100.29"
        self.assertTrue(d.container(json.dumps([obj]), "198.51.100.29")["address_matches_render"])

    def test_deep_json_is_a_probe_error_and_does_not_abort_collection(self):
        nested = "[" * 2000 + "0" + "]" * 2000
        output = io.StringIO()
        with (
            contextlib.redirect_stdout(output),
            patch.object(d, "run", return_value=({"exit_code": 0}, nested)),
        ):
            d.collect()
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(rows[-1], {**rows[-1], "complete": True})
        self.assertEqual(
            next(row for row in rows if row["probe"] == "monero-admin-info")["error"],
            "invalid-or-unavailable-reading",
        )
        with (
            contextlib.redirect_stdout(io.StringIO()),
            patch.object(
                d.Path,
                "read_text",
                side_effect=["NETWORK_SUBNET=198.51.100.0/24\nNETWORK_PREFIX=198.51.100", nested],
            ),
            patch.object(d, "run", return_value=({"error": "command-unavailable"}, None)),
        ):
            d.collect()

    def test_firewall_retains_counter_and_action_not_rules_or_comments(self):
        raw = f'[9:42] -A DOCKER-USER -s 198.51.100.3 -m comment --comment "pithead-tor-egress {PRIVATE_FIXTURE}" -j DROP\n[3:8] -A DOCKER-USER -j ACCEPT\n'
        out = d.firewall(raw, "iptables")
        self.assertEqual(
            out, {"tagged_rules": [{"packets": 9, "bytes": 42, "action": "DROP"}], "count": 1}
        )
        raw = json.dumps(
            {
                "nftables": [
                    {
                        "rule": {
                            "comment": PRIVATE_FIXTURE,
                            "expr": [
                                {"match": {"right": PRIVATE_FIXTURE}},
                                {"counter": {"packets": 9, "bytes": 42}},
                                {"drop": None},
                            ],
                        }
                    }
                ]
            }
        )
        out = d.firewall(raw, "nft")
        self.assertEqual(out["rules"][0]["packets"], 9)
        self.assertNotIn(PRIVATE_FIXTURE, json.dumps(out))

    def test_commands_are_bounded_even_with_inherited_pipe_or_ignored_term(self):
        started = time.monotonic()
        result, raw = d.run(
            [
                sys.executable,
                "-c",
                "import os,time,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.fork(); time.sleep(10)",
            ],
            seconds=0.15,
        )
        self.assertEqual(result["error"], "timeout")
        self.assertIsNone(raw)
        self.assertLess(time.monotonic() - started, 2)
        result, raw = d.run([sys.executable, "-c", "print('x'*8192)"], limit=4096)
        self.assertEqual(result["error"], "output-limit")
        self.assertIsNone(raw)
        result, raw = d.run(["/missing-diagnostics-tool"])
        self.assertEqual(result["error"], "command-unavailable")

    def test_outer_interrupt_cleans_up_the_active_probe(self):
        with patch.object(d.selectors.DefaultSelector, "select", side_effect=InterruptedError):
            with self.assertRaises(SystemExit) as raised:
                d.run([sys.executable, "-c", "import time; time.sleep(10)"])
        self.assertEqual(raised.exception.code, 143)

    def test_probe_errors_are_explicit_and_never_include_raw_data(self):
        for result, raw, error in (
            ({"exit_code": 1, "error": "command-failed"}, None, "command-failed"),
            ({"exit_code": 0}, PRIVATE_FIXTURE, "invalid-or-unavailable-reading"),
        ):
            output = io.StringIO()
            with (
                patch.object(d, "run", return_value=(result, raw)),
                contextlib.redirect_stdout(output),
            ):
                d.sample("admin", ["fixed"], d.monero_info)
            row = json.loads(output.getvalue())
            self.assertEqual(row["error"], error)
            self.assertIn("utc", row)
            self.assertNotIn(PRIVATE_FIXTURE, output.getvalue())

    def test_collect_restricted_or_unavailable_admin_does_not_request_transfers(self):
        for raw in (json.dumps({**INFO, "restricted": True}), "bad-json", None):
            commands = []

            def fake(argv, commands=commands, raw=raw):
                commands.append(argv)
                if "18085/get_info" in " ".join(argv):
                    return ({"exit_code": 0}, raw) if raw else ({"error": "timeout"}, None)
                return {"error": "command-unavailable"}, None

            output = io.StringIO()
            with patch.object(d, "run", side_effect=fake), contextlib.redirect_stdout(output):
                d.collect()
            rows = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(rows[-1]["complete"], True)
            self.assertEqual(
                [
                    r["error"]
                    for r in rows
                    if r["probe"] in {"monero-get_connections", "monero-sync_info"}
                ],
                ["admin-rpc-unverified"] * 2,
            )
            self.assertFalse(any("/json_rpc" in " ".join(cmd) for cmd in commands))
            self.assertNotIn(PRIVATE_FIXTURE, output.getvalue())

    def test_full_collection_wire_commands_and_redaction(self):
        commands = []

        def fake(argv):
            commands.append(argv)
            cmd = " ".join(argv)
            if "18085/get_info" in cmd:
                return {"exit_code": 0}, json.dumps(INFO)
            if "18085/json_rpc" in cmd:
                return {
                    "exit_code": 0
                }, '{"result":{"status":"OK","height":100,"connections":[],"peers":[],"spans":[]}}'
            if "AUTHENTICATE" in cmd:
                field = "circuit-status" if "circuit-status" in cmd else "stream-status"
                return {"exit_code": 0}, f"250 OK\n250-{field}=\n250 OK\n250 closing connection\n"
            if "/var/lib/tor/state" in cmd:
                return {"exit_code": 0}, "TotalBuildTimes 1000\nCircuitBuildAbandonedCount 1000\n"
            if "network inspect" in cmd:
                return {"exit_code": 0}, '[{"IPAM":{"Config":[{"Subnet":"198.51.100.0/24"}]}}]'
            if "ControlPort" in cmd:
                return {"exit_code": 0}, "ControlPort 198.51.100.25:9051\n"
            if "proxy=" in cmd:
                return {"exit_code": 0}, "proxy=198.51.100.25:9050\n"
            return {"error": "command-unavailable"}, None

        output = io.StringIO()
        with tempfile.TemporaryDirectory() as td:
            Path(td, ".env").write_text(
                "NETWORK_SUBNET=198.51.100.0/24\nNETWORK_PREFIX=198.51.100\nMONERO_NODE_PASSWORD="
                + PRIVATE_FIXTURE
            )
            Path(td, "config.json").write_text('{"network":{"subnet":"198.51.100.0/24"}}')
            old = os.getcwd()
            try:
                os.chdir(td)
                with patch.object(d, "run", side_effect=fake), contextlib.redirect_stdout(output):
                    d.collect()
            finally:
                os.chdir(old)
        rows = {r["probe"]: r for r in map(json.loads, output.getvalue().splitlines())}
        self.assertTrue(rows["live-network"]["summary"]["subnet_matches_render"])
        self.assertTrue(rows["tor-control-bind"]["summary"]["matches_render"])
        self.assertEqual(rows["monero-admin-info"]["summary"]["outgoing_connections_count"], 0)
        for cmd in commands:
            text = " ".join(cmd)
            self.assertNotIn(PRIVATE_FIXTURE, text)
            self.assertFalse(
                any(word in cmd for word in ("restart", "stop", "start", "down", "up", "-I", "-D"))
            )
        self.assertNotIn(PRIVATE_FIXTURE, output.getvalue())
        self.assertNotIn("198.51.100", output.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
