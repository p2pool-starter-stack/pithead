import fnmatch
import importlib.util
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/preview_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
CONTRACT_SPEC = importlib.util.spec_from_file_location(
    "preview_contract_tests", Path(__file__).with_name("preview_contract_tests.py")
)
if CONTRACT_SPEC is None or CONTRACT_SPEC.loader is None:
    raise RuntimeError("preview contract test support could not be loaded")
CONTRACT_MODULE = importlib.util.module_from_spec(CONTRACT_SPEC)
CONTRACT_SPEC.loader.exec_module(CONTRACT_MODULE)
PreviewContractTests = CONTRACT_MODULE.PreviewContractTests
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigPreviewParityTests(PreviewContractTests, unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name):
        path = self.directory / name
        path.mkdir()
        return path

    def env(self, implementation, *, binary=None, extra=None, locale="C"):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            PREVIEW_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            LC_ALL=locale,
            LANG=locale,
            NO_COLOR="1",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, work, operation, *, frame=b"", binary=None, extra=None):
        return subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work), operation],
            input=frame,
            env=self.env(implementation, binary=binary, extra=extra),
            capture_output=True,
            check=False,
            timeout=15,
        )

    def compare_describe(self, name, key, old, new, tari=b"", *, extra=None, binary=None):
        frame = b"\0".join((key, old, new, tari)) + b"\0"
        expected = self.invoke(
            "bash", self.work(name + "-bash"), "describe", frame=frame, extra=extra
        )
        actual = self.invoke(
            "go", self.work(name + "-go"), "describe", frame=frame, binary=binary, extra=extra
        )
        self.assertEqual(
            (actual.returncode, actual.stdout, actual.stderr),
            (expected.returncode, expected.stdout, expected.stderr),
        )
        return actual

    def compare_env(self, name, old, new, *, extra=None, binary=None, locale="C"):
        results = []
        for implementation in ("bash", "go"):
            work = self.work(name + "-" + implementation)
            (work / "old.env").write_bytes(old)
            (work / "new.env").write_bytes(new)
            result = subprocess.run(  # noqa: S603
                [BASH, str(ADAPTER), str(ROOT), str(work), "env-diff"],
                env=self.env(implementation, binary=binary, extra=extra, locale=locale),
                capture_output=True,
                check=False,
                timeout=15,
            )
            results.append(result)
        expected, actual = results
        self.assertEqual(
            (actual.returncode, actual.stdout, actual.stderr),
            (expected.returncode, expected.stdout, expected.stderr),
        )
        return actual

    def executable(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
        path.chmod(0o755)
        return path

    def helper(self, operation, fields):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.update(PITHEAD_GO_HELPER="config-preview", LC_ALL="C", LANG="C")
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), operation],
            env=env,
            input=b"\0".join(fields) + b"\0",
            capture_output=True,
            check=False,
            timeout=15,
        )

    def assert_clauses_covered(self, cases, sources):
        keys = {case[1] for case in cases}
        clauses = []
        for source in sources:
            text = (ROOT / source).read_text()
            clauses.extend(re.findall(r"^    ([A-Z*][A-Z0-9_* |]+)\)$", text, re.MULTILINE))
        missing = []
        for clause in clauses:
            patterns = clause.split(" | ")
            if not any(fnmatch.fnmatchcase(key, pattern) for key in keys for pattern in patterns):
                missing.append(clause)
        self.assertEqual(missing, [])

    def test_describe_every_native_case_branch_matches(self):
        cases = [
            ("prune-on", "MONERO_PRUNE", "false", "1"),
            ("prune-off", "MONERO_PRUNE", "true", "false"),
            ("profiles-local", "COMPOSE_PROFILES", "", "local_node,payout_confirm"),
            ("profiles-remote", "COMPOSE_PROFILES", "local_node", "payout_confirm"),
            ("profiles-other", "COMPOSE_PROFILES", "payout_confirm", "tari_payout_confirm"),
            ("tari-off", "TARI_MODE", "remote", "off"),
            ("tari-remote", "TARI_MODE", "off", "remote"),
            ("monero-wallet", "MONERO_WALLET_ADDRESS", "old", "new"),
            ("tari-wallet", "TARI_WALLET_ADDRESS", "old", "new"),
            ("rpc-bind-on", "MONERO_RPC_BIND", "127.0.0.1", "0.0.0.0"),
            ("rpc-bind-off", "MONERO_RPC_BIND", "0.0.0.0", "127.0.0.1"),
            ("zmq-bind-on", "MONERO_ZMQ_BIND", "127.0.0.1", "0.0.0.0"),
            ("tari-bind-on", "TARI_GRPC_BIND", "127.0.0.1", "0.0.0.0"),
            ("stratum-bind-on", "STRATUM_BIND", "127.0.0.1", "0.0.0.0"),
            ("stratum-bind-off", "STRATUM_BIND", "0.0.0.0", "127.0.0.1"),
            ("stratum-record", "STRATUM_PORT", "", "3333"),
            ("stratum-change", "STRATUM_PORT", "3333", "4444"),
            ("tls-on", "PROXY_STRATUM_TLS", "false", "true"),
            ("tls-off", "PROXY_STRATUM_TLS", "true", "false"),
            ("tls-dir", "PROXY_TLS_DIR", "/a", "/b"),
            ("password-off", "PROXY_STRATUM_PASSWORD", "secret", ""),
            ("password-change", "PROXY_STRATUM_PASSWORD", "old-secret", "new-secret"),
            ("donate", "PROXY_DONATE_LEVEL", "", "1"),
            ("dashboard-data-new", "DASHBOARD_DATA_DIR", "", "/new"),
            ("dashboard-data-move", "DASHBOARD_DATA_DIR", "/old", "/new"),
            ("chain-data", "MONERO_DATA_DIR", "/old", "/new"),
            ("generic-data", "XMRIG_DATA_DIR", "/old", "/new"),
            ("p2pool-mini", "P2POOL_FLAGS", "--foo", "--mini"),
            ("p2pool-nano", "P2POOL_FLAGS", "--mini", "--foo\t--nano x"),
            ("p2pool-word", "P2POOL_FLAGS", "--miniature", "--nanobot"),
            ("p2pool-routing", "P2POOL_FLAGS", "--mini", "--mini --foo"),
            ("p2pool-port", "P2POOL_PORT", "37888", "37889"),
            ("monero-host", "MONERO_NODE_HOST", "", "node.example"),
            ("rpc-port", "MONERO_RPC_PORT", "18081", "18082"),
            ("tari-address", "TARI_GRPC_ADDRESS", "old", "new"),
            ("node-user", "MONERO_NODE_USERNAME", "secret-old", "secret-new"),
            ("node-password", "MONERO_NODE_PASSWORD", "secret-old", "secret-new"),
            ("xvb", "XVB_ENABLED", "false", "true"),
            ("tari-required-on", "TARI_REQUIRED", "false", "true"),
            ("tari-required-off", "TARI_REQUIRED", "true", "false"),
            ("fail-closed-on", "DASHBOARD_FAIL_CLOSED", "false", "true"),
            ("fail-closed-off", "DASHBOARD_FAIL_CLOSED", "true", "false"),
            ("updates-on", "DASHBOARD_CHECK_UPDATES", "false", "true"),
            ("updates-off", "DASHBOARD_CHECK_UPDATES", "true", "false"),
            ("tari-memory", "TARI_MEM_LIMIT", "1g", "2g"),
            ("monero-memory", "MONERO_MEM_LIMIT", "1g", "2g"),
            ("dashboard-secure", "DASHBOARD_SECURE", "false", "true"),
            ("auth-off", "DASHBOARD_AUTH_HASH_B64", "secret", ""),
            ("auth-on", "DASHBOARD_AUTH_HASH_B64", "", "secret"),
            ("auth-change", "DASHBOARD_AUTH_HASH_B64", "secret-a", "secret-b"),
            ("auth-user", "DASHBOARD_AUTH_USER", "old", "new"),
            ("auth-fingerprint", "DASHBOARD_AUTH_PW_FP", "secret-a", "secret-b"),
            ("control-on", "DASHBOARD_CONTROL_ENABLED", "false", "true"),
            ("control-off", "DASHBOARD_CONTROL_ENABLED", "true", "false"),
            ("fixed-path", "CONTROL_DIR", "/old", "/new"),
            ("fixed-clearnet", "CLEARNET_STATE_DIR", "/old", "/new"),
            ("fixed-caddy", "CADDY_LOG_DIR", "/old", "/new"),
            ("onion-on", "DASHBOARD_ONION_ENABLED", "false", "true"),
            ("onion-off", "DASHBOARD_ONION_ENABLED", "true", "false"),
            ("onion-auth-on", "DASHBOARD_ONION_CLIENT_AUTH", "false", "true"),
            ("onion-auth-off", "DASHBOARD_ONION_CLIENT_AUTH", "true", "false"),
            ("onion-address", "DASHBOARD_ONION_ADDRESS", "secret-a", "secret-b"),
            ("onion-pubkey", "DASHBOARD_ONION_CLIENT_PUBKEY", "secret-a", "secret-b"),
            ("onion-private", "DASHBOARD_ONION_CLIENT_PRIVKEY", "secret-a", "secret-b"),
            ("host", "HOST_IP", "old", "new"),
            ("host-port-empty", "HOST_PORT", "", ""),
            ("host-port", "HOST_PORT", "", "8443"),
            ("prep", "MONERO_PREP_THREADS", "2", "4"),
            ("peers", "MONERO_OUT_PEERS", "16", "32"),
            ("health-off", "HEALTHCHECKS_PING_URL", "secret", ""),
            ("health-on", "HEALTHCHECKS_PING_URL", "", "secret"),
            ("health-change", "HEALTHCHECKS_PING_URL", "secret-a", "secret-b"),
            ("heal-on", "TOR_AUTO_HEAL", "false", "true"),
            ("api-secret", "XMRIG_API_TOKEN", "secret-a", "secret-b"),
            ("standby-secret", "XVB_STANDBY_SOURCE", "secret-a", "secret-b"),
            ("worker-secrets", "WORKER_API_TOKENS", "secret-a", "secret-b"),
            ("monero-clear-on", "MONERO_CLEARNET_SYNC", "false", "true"),
            ("monero-clear-off", "MONERO_CLEARNET_SYNC", "true", "false"),
            ("tari-clear-on", "TARI_CLEARNET_SYNC", "false", "true"),
            ("tari-clear-off", "TARI_CLEARNET_SYNC", "true", "false"),
            ("view-clear", "MONERO_VIEW_KEY", "secret", ""),
            ("view-set", "MONERO_VIEW_KEY", "", "secret"),
            ("view-change", "MONERO_VIEW_KEY", "secret-a", "secret-b"),
            ("wallet-password", "WALLET_RPC_PASSWORD", "secret-a", "secret-b"),
            ("payout-on", "PAYOUT_CONFIRM_ENABLED", "false", "true"),
            ("scan", "PAYOUT_SCAN_HEIGHT", "1", "2"),
            ("derived", "MONERO_RPC_URL", "secret-a", "secret-b"),
            ("derived-user", "WALLET_RPC_USERNAME", "secret-a", "secret-b"),
            ("derived-wallet", "MONERO_WALLET_RPC_URL", "secret-a", "secret-b"),
            ("tari-view-clear", "TARI_VIEW_KEY", "secret", ""),
            ("tari-view-set", "TARI_VIEW_KEY", "", "secret"),
            ("tari-view-change", "TARI_VIEW_KEY", "secret-a", "secret-b"),
            ("tari-password", "TARI_WALLET_PASSWORD", "secret-a", "secret-b"),
            ("tari-payout", "TARI_PAYOUT_CONFIRM_ENABLED", "false", "true"),
            ("tari-birthday", "TARI_WALLET_BIRTHDAY", "1", "2"),
            ("spend", "TARI_SPEND_PUBLIC_KEY", "", "public"),
            ("wallet-internal", "TARI_WALLET_SECRET_FILE", "secret-a", "secret-b"),
            ("wallet-grpc", "TARI_WALLET_GRPC_ADDRESS", "secret-a", "secret-b"),
            ("unknown", "FUTURE_KEY", "old", "new"),
        ]
        self.assert_clauses_covered(cases, ("lib/pithead/39-describe-change.sh",))
        for name, key, old, new in cases:
            with self.subTest(name=name):
                result = self.compare_describe(name, key.encode(), old.encode(), new.encode())
                self.assertEqual(result.returncode, 0)

    def test_notification_and_pure_exposure_branches_match(self):
        cases = [
            ("telegram-on", "TELEGRAM_ENABLED", "false", "true"),
            ("telegram-off", "TELEGRAM_ENABLED", "true", "false"),
            ("telegram-token", "TELEGRAM_BOT_TOKEN", "secret-a", "secret-b"),
            ("telegram-chat", "TELEGRAM_CHAT_ID", "1", "2"),
            ("commands-on", "TELEGRAM_COMMANDS_ENABLED", "false", "true"),
            ("commands-off", "TELEGRAM_COMMANDS_ENABLED", "true", "false"),
            ("wallet-alarm-off", "TELEGRAM_EVENT_WALLET_CHANGED", "true", "false"),
            ("clear-alarm-off", "TELEGRAM_EVENT_CLEARNET_EXPOSED", "true", "false"),
            ("alarm-on", "TELEGRAM_EVENT_WALLET_CHANGED", "false", "true"),
            ("empty-event", "TELEGRAM_EVENT_", "false", "true"),
            ("generic-alarm", "TELEGRAM_EVENT_NODE_DOWN", "false", "true"),
            ("unusual-alarm", "TELEGRAM_EVENT_9-WEIRD", "false", "true"),
            ("summary", "TELEGRAM_DAILY_SUMMARY_TIME", "1:00", "2:00"),
            ("webhook-off", "NOTIFY_WEBHOOK_URLS", "secret", ""),
            ("webhook-on", "NOTIFY_WEBHOOK_URLS", "", "secret"),
            ("webhook-change", "NOTIFY_WEBHOOK_URLS", "secret-a", "secret-b"),
            ("ntfy-off", "NTFY_URL", "secret", ""),
            ("ntfy-on", "NTFY_URL", "", "secret"),
            ("ntfy-change", "NTFY_URL", "secret-a", "secret-b"),
            ("ntfy-token", "NTFY_TOKEN", "secret-a", "secret-b"),
            ("notify-tor-on", "NOTIFY_TOR", "false", "true"),
            ("notify-tor-off", "NOTIFY_TOR", "true", "false"),
            ("firewall-off", "TOR_EGRESS_FIREWALL", "true", "false"),
            ("firewall-on", "TOR_EGRESS_FIREWALL", "false", "true"),
            ("xvb-tor-on", "XVB_TOR_ENABLED", "false", "true"),
            ("public-on", "DASHBOARD_EXPOSE_PUBLIC_IP", "false", "true"),
            ("public-off", "DASHBOARD_EXPOSE_PUBLIC_IP", "true", "false"),
            ("p2pool-tor", "P2POOL_CLEARNET", "true", "false"),
        ]
        self.assert_clauses_covered(
            cases,
            (
                "lib/pithead/39a-describe-change-notifications.sh",
                "lib/pithead/39b-describe-change-exposure.sh",
            ),
        )
        for name, key, old, new in cases:
            with self.subTest(name=name):
                self.compare_describe(name, key.encode(), old.encode(), new.encode())

    def test_tari_off_precedence_and_bytes_match(self):
        for key in (b"TARI_GRPC_ADDRESS", b"TARI_CLEARNET_SYNC"):
            with self.subTest(key=key):
                result = self.compare_describe("off-" + key.decode(), key, b"old", b"new", b"off")
                self.assertIn(b"inactive while merge-mining is off", result.stdout)
        self.compare_describe("unicode", b"FUTURE_KEY", "café".encode(), "雪\n\t".encode())
        self.compare_describe("invalid", b"FUTURE_KEY", b"old-\xff", b"new-\xfe")

    def test_callback_dependent_cases_fall_back(self):
        cases = [
            ("tari-local", b"TARI_MODE", b"off", b"local", {}, b""),
            ("password-on", b"PROXY_STRATUM_PASSWORD", b"", b"secret", {}, b""),
            ("heal-off", b"TOR_AUTO_HEAL", b"true", b"false", {}, b""),
            ("xvb-direct", b"XVB_TOR_ENABLED", b"true", b"false", {}, b""),
            ("p2pool-direct", b"P2POOL_CLEARNET", b"false", b"true", {}, b""),
        ]
        for name, key, old, new, extra, tari in cases:
            with self.subTest(name=name):
                self.compare_describe(name, key, old, new, tari, extra=extra)

    def test_secret_values_never_reach_preview_output(self):
        keys = (
            "PROXY_STRATUM_PASSWORD",
            "MONERO_NODE_USERNAME",
            "MONERO_NODE_PASSWORD",
            "DASHBOARD_AUTH_HASH_B64",
            "DASHBOARD_AUTH_PW_FP",
            "DASHBOARD_ONION_CLIENT_PRIVKEY",
            "HEALTHCHECKS_PING_URL",
            "XMRIG_API_TOKEN",
            "XVB_STANDBY_SOURCE",
            "WORKER_API_TOKENS",
            "MONERO_VIEW_KEY",
            "WALLET_RPC_PASSWORD",
            "TARI_VIEW_KEY",
            "TARI_WALLET_PASSWORD",
            "TELEGRAM_BOT_TOKEN",
            "NOTIFY_WEBHOOK_URLS",
            "NTFY_URL",
            "NTFY_TOKEN",
        )
        for key in keys:
            with self.subTest(key=key):
                old = ("OLD_SECRET_" + key).encode()
                new = ("NEW_SECRET_" + key).encode()
                result = self.compare_describe("secret-" + key, key.encode(), old, new)
                self.assertNotIn(old, result.stdout)
                self.assertNotIn(new, result.stdout)

    def test_env_diff_matches_comm_multiset_semantics(self):
        cases = [
            ("same", b"A=1\nB=2\n", b"B=2\nA=1\n"),
            ("add-remove-change", b"A=1\nB=2\nC=3\n", b"A=9\nC=3\nD=4\n"),
            ("duplicates", b"A=1\nA=1\nA=2\n", b"A=1\nA=2\nA=2\n"),
            ("equals", b"TOKEN=a=b=c\n", b"TOKEN=x=y\n"),
            ("comments", b"# old\n A =one\nEMPTY=\n", b"# new\n\tA =two\nEMPTY=x\n"),
            ("unterminated", b"A=1", b"A=2"),
            ("blank-lines", b"\n\nA=1\n", b"\nA=1\nB=\n"),
            ("invalid-bytes", b"A=\xff\n", b"A=\xfe\n"),
        ]
        for name, old, new in cases:
            with self.subTest(name=name):
                self.compare_env(name, old, new)


if __name__ == "__main__":
    unittest.main()
