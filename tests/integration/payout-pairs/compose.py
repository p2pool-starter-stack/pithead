"""Isolate the production wallet services and dashboard; keep their entrypoints and healthchecks."""

import json
import sys

model = json.load(sys.stdin)
project, monero_host, tari_host = sys.argv[1:]
services = {key: model["services"][key] for key in ("wallet-rpc", "tari-wallet", "dashboard")}
for name, service in services.items():
    # --no-interpolate can retain list syntax; split only the first equals sign.
    if isinstance(service["environment"], list):
        service["environment"] = {
            key: value if separator else None
            for entry in service["environment"]
            for key, separator, value in [entry.partition("=")]
        }
    for key in ("container_name", "depends_on", "profiles", "ports", "network_mode", "build"):
        service.pop(key, None)
    service["networks"] = {"mining_net": {"aliases": [f"pair-{name}"]}}
    service["pull_policy"] = "never"
services["wallet-rpc"]["image"] = "pithead-payout-pair-monero:itest"
services["dashboard"]["image"] = "pithead-payout-pair-dashboard:itest"
services["wallet-rpc"]["environment"]["MONERO_NODE_HOST"] = monero_host
services["tari-wallet"]["environment"]["TARI_BASE_NODE_GRPC_ADDRESS"] = tari_host
# Node connections are read-only, to the actual synced nodes. No miner or control sidecar runs.
env = services["dashboard"]["environment"]
env.update(
    MONERO_RPC_URL=f"http://{monero_host}:18081/json_rpc",
    TARI_GRPC_ADDRESS=tari_host,
    MONERO_WALLET_RPC_URL="http://pair-wallet-rpc:18082/json_rpc",
    TARI_WALLET_GRPC_ADDRESS="pair-tari-wallet:18143",
    DOCKER_CONTROL_URL="http://127.0.0.1:9",
    UPDATE_INTERVAL="2",
    NODE_RECOVERY_AFTER_SEC="2",
    XVB_ENABLED="false",
    XVB_SUBMIT_URL="off",
    DASHBOARD_CONTROL_ENABLED="false",
    DASHBOARD_AUTH_PASSWORD="",
)
# Only the private fixture's telemetry is mounted. The control spool and all canonical mounts go.
services["dashboard"]["volumes"] = [
    {"type": "bind", "source": "${DASHBOARD_DATA_DIR}", "target": "/data"}
]
# A real apply restarts caddy when its Caddyfile changes. The fixture serves no proxy, so give
# that restart an inert target: no network, no mounts, no capabilities.
services["caddy"] = {
    "image": "pithead-payout-pair-tools:itest",
    "command": ["sleep", "infinity"],
    "init": True,
    "network_mode": "none",
    "read_only": True,
    "cap_drop": ["ALL"],
    "security_opt": ["no-new-privileges:true"],
    "pull_policy": "never",
}
result = {
    "name": project,
    "services": services,
    "networks": {"mining_net": {"external": True, "name": model["networks"]["mining_net"]["name"]}},
    "volumes": {key: {} for key in ("wallet_data", "tari_wallet_db")},
    "secrets": {"tari_wallet_secret": model["secrets"]["tari_wallet_secret"]},
}
json.dump(result, sys.stdout)
