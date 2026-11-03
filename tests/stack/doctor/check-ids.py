import json
import re
import sys
from pathlib import Path

CHECKS = (
    ("clearnet-initial-sync", "doctor"),
    ("clock-sync", "doctor"),
    ("container-engine", "doctor"),
    ("container-engine-boot", "doctor"),
    ("container-restarts", "check_container_restarts"),
    ("container-status", "doctor"),
    ("control-units", "check_control_units"),
    ("cpu-avx2", "doctor"),
    ("dashboard-answers", "check_dashboard_answers"),
    ("dashboard-certificate", "check_appliance_cert"),
    ("dashboard-certificate-expiry", "check_appliance_cert"),
    ("dashboard-onion-address", "doctor"),
    ("dashboard-public-listener", "check_dashboard_public_listener"),
    ("data-directories", "doctor"),
    ("data-wipe-note", "check_data_wipe_note"),
    ("dependency-compose", "doctor"),
    ("dependency-docker", "doctor"),
    ("dependency-jq", "doctor"),
    ("dependency-openssl", "doctor"),
    ("deployment-completed", "doctor"),
    ("disk-space", "check_disk_grouped"),
    ("environment-file", "doctor"),
    ("free-ram", "doctor"),
    ("hugepages", "check_hugepages_reserved"),
    ("hugepages-degraded", "check_hugepages_degraded"),
    ("lan-guard", "check_lan_guard"),
    ("lan-guard-hold", "check_lan_guard_hold"),
    ("local-miner-hugepages", "check_local_miner_hugepages_blocked"),
    ("memory-platform", "doctor"),
    ("monero-address-type", "doctor"),
    ("monero-chain", "check_monero_chain"),
    ("monerod-peers-and-tip", "monerod_peers_and_tip"),
    ("monerod-synchronized", "check_monerod_synchronized"),
    ("node-onion-address", "doctor"),
    ("p2pool-tor", "doctor"),
    ("release-verification", "check_release_verification"),
    ("revenue-containers", "check_revenue_containers"),
    ("ssh-release", "doctor"),
    ("stratum-exposure", "check_stratum_exposure"),
    ("stratum-listening", "check_stratum_listening"),
    ("tari-address-type", "doctor"),
    ("tari-chain", "check_tari_chain"),
    ("tari-wallet-address", "check_tari_wallet_address"),
    ("tor-circuit-history", "check_tor_circuit_history"),
    ("tor-clearnet-egress", "check_tor_clearnet_egress"),
    ("tor-egress-firewall", "check_egress_firewall_installed"),
    ("tor-running", "check_tor_running"),
)


STUB_IDS = (
    "clearnet-initial-sync",
    "clock-sync",
    "container-engine",
    "container-engine-boot",
    "container-restarts",
    "container-status",
    "control-units",
    "cpu-avx2",
    "dashboard-answers",
    "data-directories",
    "dependency-compose",
    "dependency-docker",
    "dependency-jq",
    "dependency-openssl",
    "deployment-completed",
    "disk-space",
    "environment-file",
    "free-ram",
    "hugepages",
    "monero-address-type",
    "node-onion-address",
    "release-verification",
    "stratum-exposure",
    "stratum-listening",
    "tari-address-type",
    "tor-clearnet-egress",
    "tor-egress-firewall",
    "tor-running",
)


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def check(root, reports):
    ids = [slug for (slug, _) in CHECKS]
    require(len(ids) == len(set(ids)), "doctor id contract failed")
    catalog = dict(CHECKS)
    declared = set()
    owner = ""
    for source in (root / "lib/pithead").glob("*.sh"):
        for line in source.read_text().splitlines():
            if line.lstrip().startswith("#"):
                continue
            function = re.match("^(\\w+)\\(\\)", line)
            if function:
                owner = function[1]
            found = re.findall("\\bdr_(?:ok|warn|fail|info)(?:_surface)? ([a-z][a-z0-9-]*) ", line)
            declared.update((slug, owner) for slug in found)
    require(declared == set(CHECKS), (declared - set(CHECKS), set(CHECKS) - declared))
    for report in reports:
        document = json.loads(report.read_text())
        require(
            set(document) == {"version", "exit", "summary", "checks"}, "doctor id contract failed"
        )
        require(
            {row.get("id") for row in document["checks"]} == set(STUB_IDS),
            ({row.get("id") for row in document["checks"]}, set(STUB_IDS)),
        )
        require(document["checks"], "doctor id contract failed")
        for row in document["checks"]:
            require(set(row) == {"id", "status", "message"}, row)
            require(
                isinstance(row["id"], str)
                and re.fullmatch("[a-z][a-z0-9]*(-[a-z0-9]+)*", row["id"]),
                row,
            )
            require(row["id"] in catalog, row)
        require(
            document["summary"]
            == {
                status: sum(row["status"] == status for row in document["checks"])
                for status in ("ok", "warn", "fail", "info")
            },
            "doctor id contract failed",
        )
        require(
            document["exit"] == int(document["summary"]["fail"] > 0), "doctor id contract failed"
        )
    print(f"doctor id contract: {len(CHECKS)} pinned checks; {len(reports)} reports passed")


if __name__ == "__main__":
    check(Path(sys.argv[1]), [Path(value) for value in sys.argv[2:]])
