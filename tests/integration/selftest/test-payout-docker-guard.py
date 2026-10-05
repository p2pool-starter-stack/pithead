"""Fixture apply cannot stop canonical nodes or borrow their storage through Docker."""

import http.client
import importlib.util
import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "payout_guard", Path(__file__).resolve().parents[1] / "payout-pairs/docker_guard.py"
)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
LABEL = {"com.docker.compose.project": "fixture"}
BODY = {"Labels": LABEL, "HostConfig": {"CapDrop": ["ALL"]}}


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.policy = guard.Policy("fixture", self.inspect, self.work.name)

    @staticmethod
    def inspect(kind, name):
        if name.startswith("new-") or name == "fixture_new":
            return {}
        project = (
            "fixture" if (name.startswith("fixture_") or name == "0123456789ab") else "pithead"
        )
        labels = {"com.docker.compose.project": project}
        return {"Config": {"Labels": labels}} if kind == "containers" else {"Labels": labels}

    def test_canonical_nodes_and_interrupted_recreates_cannot_be_mutated(self):
        for name in ("monerod", "tari", "deadbeef_monerod", "unknown-id"):
            for action in ("stop", "start", "rename", "kill", "restart", "exec"):
                self.assertFalse(
                    self.policy.allows("POST", f"/v1.47/containers/{name}/{action}", {})
                )
            self.assertFalse(self.policy.allows("DELETE", f"/containers/{name}", {}))
            self.assertFalse(self.policy.allows("GET", f"/containers/{name}/json", {}))

    def test_only_fixture_names_labels_and_owned_mutations_pass(self):
        for kind in ("containers", "volumes", "networks"):
            path = f"/{kind}/create?name=fixture_wallet-1"
            for labels in ({}, {"com.docker.compose.project": "pithead"}):
                self.assertFalse(self.policy.allows("POST", path, {"Labels": labels}))
            self.assertTrue(self.policy.allows("POST", path, {**BODY, "Name": "fixture_wallet"}))
            self.assertTrue(self.policy.allows("DELETE", f"/{kind}/fixture_wallet", {}))
            self.assertFalse(self.policy.allows("DELETE", f"/{kind}/canonical", {}))
        self.assertFalse(
            self.policy.allows("POST", "/containers/create?name=monerod", {"Labels": LABEL})
        )
        self.assertFalse(
            self.policy.allows(
                "POST", "/volumes/create", {"Name": "pithead_wallet_data", "Labels": LABEL}
            )
        )
        self.assertTrue(self.policy.allows("POST", "/containers/fixture_wallet/start", {}))

    def test_compose_recreation_requires_owned_replaced_container(self):
        self.assertTrue(
            self.policy.allows(
                "POST", "/containers/create?name=0123456789ab_fixture-wallet-1", BODY
            )
        )
        self.assertFalse(
            self.policy.allows(
                "POST", "/containers/create?name=deadbeef0123_fixture-wallet-1", BODY
            )
        )
        self.assertFalse(
            self.policy.allows("POST", "/containers/create?name=0123456789ab_monerod", BODY)
        )
        self.assertTrue(
            self.policy.allows(
                "POST", "/containers/fixture_wallet/rename?name=fixture-wallet-1", {}
            )
        )
        self.assertFalse(
            self.policy.allows("POST", "/containers/fixture_wallet/rename?name=monerod", {})
        )

    def test_creation_cannot_mount_foreign_storage_or_host_namespaces(self):
        path = "/containers/create?name=fixture_wallet-1"
        self.assertFalse(self.policy.allows("POST", path, {"Labels": LABEL}))
        self.assertFalse(
            self.policy.allows(
                "POST",
                "/volumes/create",
                {"Labels": LABEL, "Name": "fixture_new", "Driver": "foreign-driver"},
            )
        )
        for source in ("/var/run/docker.sock", "/opt/pithead/data", "pithead_wallet_data"):
            for mount in (
                {"Binds": [source + ":/data"]},
                {
                    "Mounts": [
                        {"Type": "bind" if source.startswith("/") else "volume", "Source": source}
                    ]
                },
            ):
                self.assertFalse(
                    self.policy.allows(
                        "POST", path, {"Labels": LABEL, "HostConfig": {"CapDrop": ["ALL"], **mount}}
                    )
                )
        for host in (
            {"Privileged": True},
            {"DeviceCgroupRules": ["b *:* rwm"]},
            {"VolumeDriver": "foreign-driver"},
            {"NetworkMode": "host"},
            {"PidMode": "host"},
            {"IpcMode": "host"},
            {"UsernsMode": "host"},
            {"CapAdd": ["SYS_ADMIN"]},
            {"VolumesFrom": ["monerod"]},
            {
                "Mounts": [
                    {
                        "Type": "volume",
                        "Source": "fixture_wallet",
                        "VolumeOptions": {
                            "DriverConfig": {"Name": "local", "Options": {"device": "/"}}
                        },
                    }
                ]
            },
        ):
            self.assertFalse(
                self.policy.allows(
                    "POST", path, {"Labels": LABEL, "HostConfig": {"CapDrop": ["ALL"], **host}}
                )
            )
        self.assertFalse(
            self.policy.allows(
                "POST",
                "/volumes/create",
                {"Labels": LABEL, "Name": "fixture_wallet", "DriverOpts": {"device": "/"}},
            )
        )
        host = {
            "Binds": [self.work.name + "/build:/wallet-config:ro"],
            "Mounts": [{"Type": "volume", "Source": "fixture_wallet"}],
            "CapAdd": ["CHOWN", "SETUID", "SETGID", "DAC_OVERRIDE"],
        }
        self.assertTrue(
            self.policy.allows(
                "POST", path, {"Labels": LABEL, "HostConfig": {"CapDrop": ["ALL"], **host}}
            )
        )
        link = Path(self.work.name) / "escape"
        link.symlink_to("/opt")
        self.assertFalse(self.policy.mount_allowed("bind", str(link / "pithead")))

    def test_null_host_config_lists_are_treated_as_empty(self):
        # Compose serialises unset list fields as JSON null, not as absent keys.
        host = {"CapDrop": ["ALL"], "CapAdd": None, "Binds": None, "Mounts": [{"Type": "tmpfs"}]}
        path = "/containers/create?name=fixture_wallet-1"
        self.assertTrue(self.policy.allows("POST", path, {"Labels": LABEL, "HostConfig": host}))
        self.assertFalse(
            self.policy.allows(
                "POST", path, {"Labels": LABEL, "HostConfig": {**host, "CapDrop": None}}
            )
        )

    def test_denial_names_the_rule_without_the_body(self):
        path = "/containers/create?name=fixture_wallet-1"
        host = {"CapDrop": ["ALL"], "CapAdd": ["SYS_ADMIN"]}
        self.assertFalse(self.policy.allows("POST", path, {"Labels": LABEL, "HostConfig": host}))
        self.assertEqual(self.policy.why, "capability added")
        self.assertFalse(self.policy.allows("POST", "/images/prune", {}))
        self.assertEqual(self.policy.why, guard.Policy.default_why)

    def test_external_network_reads_and_owned_connects_only(self):
        self.assertTrue(self.policy.allows("GET", "/networks/mining_net", {}))
        self.assertFalse(
            self.policy.allows("POST", "/networks/mining_net/connect", {"Container": "monerod"})
        )
        self.assertTrue(
            self.policy.allows(
                "POST", "/networks/mining_net/connect", {"Container": "fixture_wallet"}
            )
        )
        for path in ("/containers/prune", "/images/prune", "/build"):
            self.assertFalse(self.policy.allows("POST", path, {}))
        self.assertTrue(self.policy.allows("GET", "/version", {}))

    def test_http_relay_preserves_missing_volume_then_allows_fixture_create(self):
        class Response:
            def __init__(self, status):
                self.status, self.payload = status, b"{}"

            def getheaders(self):
                return [
                    ("Content-Length", str(len(self.payload))),
                    ("Content-Type", "application/json"),
                ]

            def read(self):
                result, self.payload = self.payload, b""
                return result

            def read1(self, _size):
                result, self.payload = self.payload, b""
                return result

        forwarded = []

        class Connection:
            def request(self, method, path, body, _headers):
                forwarded.append((method, path, body))
                self.status = 404 if method == "GET" else 201

            def getresponse(self):
                response = Response(self.status)
                if forwarded[-1][1] == "/v1.47/containers/json":
                    response.status = 200
                    response.payload = json.dumps(
                        [
                            {"Id": "mine", "Labels": LABEL},
                            {"Id": "foreign", "Labels": {"com.docker.compose.project": "pithead"}},
                        ]
                    ).encode()
                return response

            def close(self):
                pass

        # Real HTTP handler and sockets, synthetic daemon only. No Docker is needed.
        path = str(Path(self.work.name) / "guard.sock")

        class Client(http.client.HTTPConnection):
            def connect(self):
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.settimeout(5)
                self.sock.connect(path)

        with guard.Server(path, guard.Handler) as server:
            server.policy = self.policy
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            try:
                with patch.object(guard, "DockerConnection", Connection):
                    client = Client("localhost")
                    client.request("GET", "/volumes/fixture_new")
                    response = client.getresponse()
                    self.assertEqual(response.status, 404)
                    response.read()
                    client.request(
                        "POST",
                        "/volumes/create",
                        json.dumps({"Labels": LABEL, "Name": "fixture_new"}),
                    )
                    response = client.getresponse()
                    self.assertEqual(response.status, 201)
                    response.read()
                    client.request("GET", "/containers/monerod/json")
                    response = client.getresponse()
                    self.assertEqual(response.status, 403)
                    response.read()
                    client.request("GET", "/v1.47/containers/json")
                    response = client.getresponse()
                    self.assertEqual(json.loads(response.read()), [{"Id": "mine", "Labels": LABEL}])
                    client.request(
                        "POST",
                        "/containers/create?name=0123456789ab_fixture-wallet-1",
                        json.dumps(BODY),
                    )
                    response = client.getresponse()
                    self.assertEqual(response.status, 201)
                    response.read()
                    client.request(
                        "POST", "/containers/fixture_wallet/rename?name=fixture-wallet-1"
                    )
                    response = client.getresponse()
                    self.assertEqual(response.status, 201)
                    response.read()
                    client.close()
            finally:
                server.shutdown()
                worker.join()
        self.assertEqual(len(forwarded), 5)


if __name__ == "__main__":
    unittest.main()
