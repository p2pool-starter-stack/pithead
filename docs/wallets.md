# Connecting a Wallet

How to point an external Monero wallet — one running on your phone or another machine, not the
dashboard — at the bundled node's RPC, so it can sync and check your balance against your own node
instead of a public one.

> This is for a *wallet*, not another Pithead/P2Pool stack. If you're pointing another stack's
> P2Pool at this node instead, see [Connecting to a remote Monero
> node](configuration.md#connecting-to-a-remote-monero-node) — it needs ZMQ too, a wallet doesn't.

---

## Enable RPC access

The node's RPC (`18081`) is localhost-only by default. Turn on
[`monero.rpc_lan_access`](configuration.md#configuration-reference), then apply:

```jsonc
// config.json
"monero": { "rpc_lan_access": true }
```

```bash
./pithead apply
```

The flag only takes effect once `apply` re-renders `.env` and recreates the `monerod` container —
editing `config.json` alone does nothing.

`monero.zmq_lan_access` is a separate switch and **not needed for a wallet** — it's the block-notify
feed a remote P2Pool consumes, wallets don't use it. Leave it off; turning it on only widens exposure
(the ZMQ pub has no authentication at all — see [Security](#security) below).

## Point the wallet at it

- **Node address:** `<stack-host>:18081` (the host's LAN IP or hostname, port `18081`).
- **Credentials:** the node always requires digest auth (`restricted-rpc=1` is unconditional —
  the same setting public nodes run), so the wallet needs a username and password, not just the
  address.

Read them from `config.json` on the stack host:

```bash
jq -r '.monero.node_username, .monero.node_password' config.json
```

These are auto-generated on `setup`/every `apply` (username `admin`, a random password) and are
**not** shown by `pithead status` or the dashboard's config view (masked there like any other
secret) — `config.json` is the only place to read them.

Any wallet that supports a custom daemon with RPC login works, for example
[monero-wallet-gui](https://github.com/monero-project/monero-gui) (the official GUI wallet),
[Feather](https://featherwallet.org/), or [Cake Wallet](https://cakewallet.com/) — named here as
compatible options, not endorsements.

## Verify with a raw RPC call

Confirming the node answers before configuring a wallet narrows down a failure: a connection error
means the port or firewall, an auth error means the credentials.

```bash
curl --digest -u "$MONERO_NODE_USERNAME:$MONERO_NODE_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' \
  http://<stack-host>:18081/json_rpc
```

A working node returns a JSON body with `"status":"OK"`. Wrong credentials return `401`; no
response at all (connection refused/timeout) means the port isn't reachable — check
`rpc_lan_access`, that `apply` ran, that the wallet's address is a LAN address (see
[Security](#security)), `./pithead doctor` for a port held on `127.0.0.1`, and any firewall
between the wallet and the host.

## Security

The RPC is digest-auth'd, but that auth rides plaintext HTTP — no TLS. Treat it as LAN-only:

- LAN sources only. The stack drops connections to `18081` from any address outside loopback,
  `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` and `100.64.0.0/10`, so a port-forward from the
  internet does not work. Use [WireGuard](https://www.wireguard.com/) or
  [Tailscale](https://tailscale.com/) to reach it from outside your LAN. See
  [LAN-only sources](configuration.md#lan-only-sources).
- Docker publishes container ports with its own `iptables` rules, ahead of the `INPUT` chain a host
  firewall (`ufw`, plain `iptables`) usually configures. A rule that looks like it blocks `18081`
  may not — see [Connecting Miners › Firewall](workers.md#firewall) for the same caveat on the
  stratum port, and test with the `curl` call above from off-host, not just by reading the rules.

## See also

- [Configuration](configuration.md#configuration-reference) — `monero.rpc_lan_access`,
  `monero.node_username` / `node_password`.
- [Connecting to a remote Monero node](configuration.md#connecting-to-a-remote-monero-node) — the
  P2Pool-to-P2Pool case, which also needs ZMQ.
- [Connecting Miners › Firewall](workers.md#firewall) — the Docker/`iptables` interaction in more
  detail.
