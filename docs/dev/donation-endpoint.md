# Donation endpoint runbook

This runbook describes an operator-hosted P2Pool mini endpoint for XMRig donation traffic.

## Operating boundary

Follow the operating policy in [issue #3699](https://github.com/p2pool-starter-stack/pithead/issues/3699). Use a dedicated public project payout address for the endpoint; P2Pool payouts and wallet addresses are public ([pinned README](https://github.com/SChernykh/p2pool/blob/v4.18.1/README.md#general-considerations)). Keep it separate from personal payout addresses, and do not co-host personal addresses on the endpoint. Run the endpoint outside the home network. Expose the P2Pool mini Stratum endpoint through a Tor onion service only; do not publish a clearnet Stratum address.

Per-pool SOCKS and onion behavior has not been measured in a deployed endpoint; verify routing and reachability from the running host before accepting traffic. The pinned P2Pool release is v4.18.1 ([build pin](../../build/p2pool/Dockerfile), [command-line reference](https://github.com/SChernykh/p2pool/blob/v4.18.1/docs/COMMAND_LINE.MD)). `--mini` selects the mini sidechain, `--wallet` selects the Monero payout address, `--stratum` sets the Stratum listener, `--socks5` routes outgoing connections through SOCKS5, and `--onion-address` advertises the node's onion address. Confirm the deployed release and rendered arguments before changing these settings.

XMRig Proxy is pinned to v6.26.0 ([build pin](../../build/xmrig-proxy/Dockerfile); [upstream README](https://github.com/xmrig/xmrig-proxy/blob/v6.26.0/README.md)). Its `simple` mode uses a separate upstream mapper for each connected miner: [SimpleSplitter](https://github.com/xmrig/xmrig-proxy/blob/v6.26.0/src/proxy/splitters/simple/SimpleSplitter.cpp) creates a mapper for a new miner, and [SimpleMapper](https://github.com/xmrig/xmrig-proxy/blob/v6.26.0/src/proxy/splitters/simple/SimpleMapper.cpp) creates and connects that mapper's pool strategy. The stack selects `-m simple` in [Compose](../../docker-compose.yml). If every rig in each donor's stack routes project work at once, endpoint connections scale with participating rigs summed across donors. For equal-sized donor fleets this is rigs per donor times active donors. Idle mapper reuse and failover affect the actual count; measure it with the deployed configuration.

## Configure and operate

1. Create a dedicated project Monero payout address and record it in the operator's private deployment configuration. If Tari merge mining is enabled, create a dedicated project Tari payout address too. Do not put either address in this runbook.
2. Provision an off-home-network host with an operator-approved storage, memory, and bandwidth budget. Unmeasured sizing rule of thumb: budget from the maximum simultaneously donating rig count, allow headroom for idle mapper reuse, and increase capacity before measured connection, disk or RAM limits are reached. Size the host from a representative load test before production use.
3. Configure P2Pool for mini sidechain, the dedicated project address, and a loopback-only Stratum listener. Forward the onion service's Stratum port to that listener; do not bind Stratum on a public interface. The onion-address flag advertises P2Pool peer connectivity, not the Stratum service. Route P2Pool's outgoing peer traffic through SOCKS/Tor and verify that incoming Stratum access is available only through the onion service. P2Pool documents `--mini`, `--socks5`, and `--onion-address` in its pinned [command-line reference](https://github.com/SChernykh/p2pool/blob/v4.18.1/docs/COMMAND_LINE.MD).
4. Have each donor stack route its project donation slice from its own XMRig Proxy to the onion Stratum endpoint. The project endpoint mines to the dedicated project address set by P2Pool's `--wallet`; miners cannot select a different payout wallet through their login ([pinned README](https://github.com/SChernykh/p2pool/blob/v4.18.1/README.md#mining-on-gnulinux)). An onion service needs no exit relay and its address authenticates the service identity ([Tor onion service properties](https://community.torproject.org/onion-services/overview/)). Verify each donor's SOCKS path before go-live.
5. Observe the proxy and P2Pool logs and status continuously. Track accepted and rejected shares, connected workers, sidechain synchronization and peer connectivity, disk use, and memory use. Investigate sustained rejected shares, loss of sidechain sync, or resource pressure before increasing worker load.
6. Keep the host patched and restrict administration to the operator's management path. Verify backups or recovery procedures for the endpoint's persistent P2Pool data before relying on the service.

Use placeholders in deployment templates and examples: `<PROJECT_MONERO_ADDRESS>`, `<PROJECT_TARI_ADDRESS>`, `<ENDPOINT_ONION_ADDRESS>`, `<STRATUM_PORT>`, and `<SOCKS_ADDRESS>`. Replace them only in private deployment configuration. These placeholders are not valid configuration values.

## Release and address changes

The planned constants mechanism is owner-authored: a constants update carries address rotations, while a release with empty constants acts as a kill switch. It has no remote kill path. A donor that has not installed the updated release can continue dialing the older endpoint; the slowest donor's update time has no guaranteed finite maximum. Plan address rotations and service shutdowns with that uncertainty in mind. This behavior is a design constraint for the planned mechanism, not a measured deployment result.

## Open decisions

- Which operator owns the endpoint and its incident response?
- Which host, location, and network provider meet the off-home-network requirement?
- What storage, memory, bandwidth, and cost budget will be approved after load measurement?
- What uptime target, maintenance window, and recovery arrangement are required?
- Is high availability required, and how will a replacement endpoint retain its onion identity?
- Is Tari merge mining in scope, and who creates and controls its dedicated project payout address?
- What release cadence and address-rotation procedure will operators support given that donor update time has no finite maximum?
