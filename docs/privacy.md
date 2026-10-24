# Privacy & network egress

This doc lists every connection the stack makes off your box: where it goes, whether it's routed
over Tor, whether it's on by default, and how to lock it down.

The selected profile controls which documented connections use Tor. Explicit governed settings
override the profile, and remote node modes do not enable local sync flags.

`balance` is the default when `profile` is absent. `performance` keeps local node operation and the
listed performance-sensitive outbound services on clearnet; `balance` uses Tor for governed privacy
paths; `privacy` adds onion-only P2Pool peering and generated worker API authentication. What's left
is inherent: the one-time install/build reveals your IP to the download host, and remote-node mode
(`monero.mode: remote` and `tari.mode: remote`) talks to the node you choose.

The [profile-controlled initial sync](#profile-controlled-initial-sync) section describes how
Monero and Tari use clearnet or Tor for local operation. Remote modes force their sync flags false.

---

## Enforced fail-closed, not just configured (#270)

Every per-app Tor setting below is backed by a host firewall, so "behind Tor" is a property the
stack enforces, not one it merely hopes each daemon is configured for. At `up`/`apply`, `pithead`
installs a fail-closed rule set on the mining subnet: the mining bridge (monerod, p2pool, tari,
xmrig-proxy) may reach the LAN, the other containers, and the Tor SOCKS, but any direct dial to the
public internet is DROPPED unless its address has an explicit clearnet choice: temporary node
sync, P2Pool sidechain peers, or enabled XvB donation. Otherwise only the `tor` container reaches
the internet. So if a daemon is
misconfigured, buggy, or learns a clearnet peer address (as Tari's comms layer does), the connection
fails closed instead of leaking your IP.

Connection tracking lets replies through, which keeps clients on the published ports working, and
nothing else. A clearnet connection an app opened while the rules were absent (a host firewall
reload that flushed them, a `down` followed by a manual container start) does not survive their
return: the next TCP packet the app sends on it is answered with a reset, and any other packet is
dropped. What the app sent before the rules went back in has already left the box. A re-install
never opens such a window itself: `up`, `apply` and `upgrade` replace the rules in one kernel
transaction (`iptables-restore --noflush` on Docker, one `nft -f` on the appliance), and a load
the kernel refuses leaves the rules already there in place.

The rules land where the running container engine actually filters forwarded traffic, which differs
by channel:

- **Docker (DIY channel):** the rules go in Docker's `DOCKER-USER` chain. Docker adds the
  `FORWARD → DOCKER-USER` jump when it creates the network, so the chain is traversed on egress.
  A reboot empties the chain, and the containers restart on their own when Docker starts, so
  `pithead` also installs `pithead-egress.service`: a oneshot unit ordered before
  `docker.service` and pulled in by it, carrying the same rules. It inserts the `DROP` first,
  so a start that fails halfway blocks more than intended rather than less. Its P2Pool and XvB
  accepts check separate current-choice markers at boot. Disabling a choice removes its boot
  marker before refreshing the live rules; a shared guard still blocks startup until the host
  verifies that the old live exception is gone.
- **podman + netavark (appliance):** netavark serves the forward hook from its own nftables table and
  never adds a `DOCKER-USER` jump, so the same iptables rules would sit in a chain no packet reaches.
  `pithead` instead installs an independent `inet pithead_egress` nftables table hooked at forward
  priority −5 — ahead of netavark's blanket accept, owning no chain shared with netavark so it
  survives netavark reprogramming its own table.

`pithead doctor` reads whichever mechanism the running engine uses and checks the drop is in a chain
that is actually hooked at forward, so it cannot report enforced while the rules are orphaned. The
install reads the same live state back before it reports success, so "Tor-only egress enforced" in
the log means the rules were found in the kernel, not that the install command exited zero. A host
whose engine has no firewall backend installed at all cannot enforce anything, so `doctor` FAILs
there rather than skipping the check — on the appliance that is what stops a slot with no firewall
from committing itself as healthy.

The dashboard runs in a container and cannot read host firewall rules, so it does not take the
firewall's state from `network.tor_egress_firewall` alone. `up`, `apply` and `upgrade` install
`pithead-egress.timer`, which runs `pithead egress-status` two minutes after boot and every two
minutes after that. The check is the one `doctor` uses, it is read-only, and it writes its verdict
to `data/control/results/egress-status.json`. The dashboard reads that file:

- **Enforced:** unselected clearnet routes on the mining subnet show as blocked; selected routes
  show the operator's choice and IP exposure.
- **Missing** (rules absent, no firewall tool, no jump into the chain, or a foreign rule above the
  `DROP`): the **Stack Topology & Egress** panel and the header badge warn that the firewall is
  missing, nothing is shown as blocked, and one `clearnet_exposed` alert goes out. A second alert
  goes out when the check reads enforced again. Run `./pithead up` to reinstall the rules. The
  check never reinstalls them itself, so a flush stays visible until you act on it.
- **Unverified** (no status file yet, an unreadable ruleset, no check for six minutes, or a file
  whose fields are not a JSON integer `rc` and a finite JSON number `checked_at`): the panel and
  badge warn that the state is unverified, and no alert goes out. A malformed file never reads as
  enforced.

Opting out with `network.tor_egress_firewall: false` removes the timer. If a removal step fails
(stopping the timer, deleting its unit files, or reloading systemd), `apply` names the step and
does not report the timer removed, and `uninstall` exits non-zero instead of printing
`Uninstalled.`

The allow-set matches on IPv4 addresses because the mining bridge is IPv4-only by design. On the
appliance path the firewall also fences IPv6: if the mining network ever gains an IPv6 subnet, an
address match has nothing to key on (there is no assigned v6 range), so the drop is scoped to the
mining bridge interface instead — the v6 LAN (ULA `fc00::/7` and link-local `fe80::/10`) is allowed
and everything else the bridge originates is dropped, leaving the host's own IPv6 forwarding on every
other interface untouched. If a v6 subnet is present but the bridge interface can't be resolved,
`pithead` refuses to install a v4-only firewall it would otherwise report as fail-closed.

- Needs root (the firewall rules), like the GRUB/HugePages steps; removed at `pithead down`. The
  DIY boot unit stays through `down` and is removed by `uninstall` or by opting out.
- Opt out with `network.tor_egress_firewall: false` (then routing falls back to per-app config only).
- The accepted destinations are the private ranges only: `10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`, and `100.64.0.0/10` (CGNAT, so Tailscale addresses work). A remote Monero or
  Tari node must sit in one of them — a node at a public IP is dropped with everything else, by
  design.
- The host-networked dashboard and caddy aren't on the bridge; the dashboard's external calls go
  over the Tor SOCKS (`socks5h`, [#163](#runtime-egress)/#224), except for configured remote
  nodes. With `tari.mode: remote` the dashboard reads that node over gRPC directly; with
  `monero.mode: remote` it probes the configured RPC directly. Both are un-proxied,
  like p2pool's remote-node connections.
- Verify it live with [`tests/integration/benchmarks/bench-verify-egress.sh`](../tests/integration/benchmarks/bench-verify-egress.sh): the `tor` arm requires zero app-container public connections, while `p2pool-choice` requires P2Pool peers and zero other app dials. It names each connection as an outbound dial or an inbound client on a published port.

On the Docker (DIY) channel, the enforcement check above walks `DOCKER-USER` looking for a rule
that would shadow our DROP, written by something else that shares the chain — ufw-docker, a second
Compose project. At boot, the LAN guard runs first and Pithead reinstalls the egress rules above
its LAN-port jumps before starting containers, so the guard's return path still reaches the DROP.
Until the host attests a selected first sync's Tor transition, a failed live firewall readback
prevents Compose startup. A selected
P2Pool or XvB exception also refuses startup on refresh failure; after a choice is disabled, its
marker keeps that refusal through firewall opt-out until an enabled refresh proves the stale rule
gone. Ordinary startup retains the firewall warning. Before Docker creates its first network,
the absent `FORWARD` jump is allowed only when Docker confirms the mining network is absent and no
mining container runs; Docker then adds the jump.
The check does CIDR-containment math, not a literal string match: a foreign `ACCEPT` or
`RETURN` rule scoped with `-s` to any network that overlaps the mining subnet — a wider supernet
containing it, or a narrower range inside it, negated (`! -s`) or not — is recognized as shadowing,
in addition to an unscoped rule or one scoped to exactly the mining subnet
([pithead#2117](https://github.com/p2pool-starter-stack/pithead/issues/2117)). A rule scoped only
with `-d` (destination) is covered conservatively rather than precisely: the walk doesn't do
CIDR math on `-d`, so any `-d`-scoped rule is treated the same as an unscoped one and flagged as
shadowing, whether or not it could actually match our traffic — safe, but not exact.
`pithead doctor` reports the shadowed case as not-enforced. This only matters if something else on
the same host also writes rules into `DOCKER-USER`; the podman/netavark appliance path proves
reachability structurally instead of by rule-scanning, so it does not have this gap.

The check reads each `DOCKER-USER` rule as tokens rather than scanning it as text, honouring the
quoting `iptables` itself uses, so `-s` counts only as a flag of its own and a foreign rule's own
free-text values — a `--comment`, an `-m string --string`, anything quoted — are values that can
never be read as flags, whatever they spell. Three earlier substring-scanning versions of this
check could each be talked out of a correct verdict by a crafted match value, the last of them
reported as a live fail-open ([pithead#2129](https://github.com/p2pool-starter-stack/pithead/issues/2129));
the tokeniser replaces that shape rather than patching it. There is no fallback path: a rule the
tokeniser cannot read unambiguously — an unterminated quote, a `-s` whose value is not an address,
two sources on one rule — is reported as shadowing, never as harmless.

---

## Inbound — no port forwarding

Your home IP is never advertised to an inbound peer, and you never touch your router's port-forward
settings. Monerod and Tari accept inbound peers through Tor hidden services. P2Pool inbound peering
uses a source-restricted Tor service bridge on its existing P2Pool peer port; the bridge has no host
or LAN publish and never forwards RPC or stratum. A node you run
elsewhere (`monero.mode` / `tari.mode: remote`) accepts its own peers, so Tor publishes no onion for
it — only services that actually run here get an address. Tor reaches the bundled Monero node on
its bridge-bound anonymous P2P listener at `:18084`; that port is not published on the host.
P2Pool's onion reaches only the selected sidechain's P2P listener. So:

- No public IPv4 port forwarding is required, and your IP is not advertised to inbound peers.
- Two things face the LAN by default: the dashboard, served by the host-networked Caddy on `:443`
  behind its login, and the stratum endpoint your rigs connect to (`p2pool.stratum_port`, default
  `3333`). Stratum is plain and unauthenticated by default, and neither should ever face the
  internet: `pithead setup`/`doctor` warn if your host has a public IP. Lock it down with `p2pool.stratum_bind`, a
  firewall, and/or an optional `p2pool.stratum_password` that requires each rig to authenticate.
  See [Connecting Miners › Firewall](workers.md#firewall) and [Authentication](workers.md#authentication).
- The **dashboard** can get one more, optional onion (`dashboard.onion.enabled`, default off) so you
  can reach it remotely over Tor without a port-forward or public IP. It fronts the authenticated
  Caddy login, defaults to Tor v3 client authorization (the onion won't respond without your client
  key), and pithead refuses to publish it without a 16-character password. This is **inbound** access
  over Tor and does not change the egress table below. See
  [Remote access over Tor](configuration.md#remote-access-over-tor-onion-service).

---

## Runtime egress

What the running stack sends to the internet, connection by connection.

| Connection | Destination | What it could reveal | Tor? | Default | How to control |
|---|---|---|---|---|---|
| **monerod** P2P + tx broadcast | Monero network | — | `performance`: direct P2P; `balance`/`privacy`: Tor (`proxy=` / `tx-proxy=`) | on | profile and explicit sync flags govern local nodes; remote mode forces sync false |
| **monerod** DNS (checkpoints, blocklist, update check, priority-node hostnames) | DNS resolvers | "this IP runs Monero" | ✅ **closed** — `disable-dns-checkpoints`, `check-updates=disabled`, `enable-dns-blocklist=0`, hostname priority-nodes dropped (#161) | n/a | — |
| **monerod RPC to a remote node** (only if `monero.mode: remote`) | the node you configured | **your real home IP**, to that node's operator | ❌ clearnet | **off** — the bundled local node is the default and has no remote-RPC egress | use a node you run on your LAN or reachable over WireGuard; a `.onion` remote isn't supported — with Tor on, p2pool's socat bridge moves this leg off the SOCKS5 proxy before it could reach Tor |
| **Tari** P2P | Tari network | — | `performance`: direct TCP; `balance`/`privacy`: Tor SOCKS (`type = "socks5"`) | on | profile and explicit sync flags govern local nodes; remote or off mode forces sync false |
| **Tari** DNS seeds + Pulse (`seeds.tari.com`, `checkpoints.tari.com`) | DNS resolvers | "this IP runs Tari" | ✅ **closed** — `dns_seeds = []` and onion `peer_seeds` prevent seed lookups; Pulse's advisory lookup fails at the isolated loopback resolver, so no DNS packet leaves the host (#162) | n/a | `performance` or an explicit clearnet sync override re-enables the `seeds.tari.com` DNS seed |
| **P2Pool** merge-mine gRPC to a remote Tari node (only if `tari.mode: remote`) | the node you configured | **your real IP**, to that node's operator | ❌ clearnet — same posture as monerod's own remote-node RPC above | **off** — the bundled local Tari node is the default and this leg only exists in remote mode | use a node on your LAN or reachable over WireGuard; a `.onion` remote isn't supported yet (see [Configuration › Remote Tari node](configuration.md#remote-tari-node)) |
| **Dashboard** sync poll to a remote Monero node (only if `monero.mode: remote`) | the configured RPC | **your real IP**, to that node's operator | ❌ direct HTTP with configured RPC digest auth | **off** — local Monero is the default | use a node on your LAN or reachable over WireGuard; polling detects outages so workers fail over |
| **Dashboard** sync poll to a remote Tari node (only if `tari.mode: remote`) | the node you configured | **your real IP**, to that node's operator | ❌ clearnet — a plaintext gRPC dial, and the host-networked dashboard sits outside the Tor-egress firewall | **off** — only exists in remote mode | same as the p2pool leg above: LAN or WireGuard |
| **P2Pool** inbound peers | reach you via onion | — | ✅ onion hidden service | on | — |
| **P2Pool** outbound sidechain peers | P2Pool sidechain peers | — | `balance`/`privacy`: ✅ Tor; `performance`: ❌ direct clearnet | profile-dependent | `privacy` adds `--no-clearnet-p2p`; an explicit `p2pool.clearnet` value wins. Inbound onion peering is separate and remains on the source-restricted bridge |
| **P2Pool** DNS seeds (`seeds-mini.p2pool.io`, `mini.p2poolpeers.net`, or the `main`/`nano` equivalents) | DNS resolvers | "this IP runs P2Pool" | ✅ **closed** — `--no-dns` with the Tor default, so peers come from the saved peer list and the onion seed nodes (#2496) | n/a | `p2pool.clearnet: true` re-enables the DNS seeds along with clearnet peering |
| Dashboard **XvB stats** fetch | `xmrvsbeast.com` | your Monero **wallet** | `performance`: direct; `balance`/`privacy`: Tor (`socks5h`, #163) | on, only if XvB enabled | `XVB_ENABLED=false` stops it; profile governs routing |
| Dashboard **XvB raffle registration** (#263) | `xmrvsbeast.com` | your Monero **wallet** | `performance`: direct; `balance`/`privacy`: Tor (`socks5h`) | on, only if XvB enabled; fires once you have a PPLNS share | `XVB_ENABLED=false`, or set `XVB_SUBMIT_URL` to `off`, to stop it |
| Dashboard **XvB winners fetch** (raffle-wins display) | `xmrvsbeast.com` | nothing — the winners file is public | `performance`: direct; `balance`/`privacy`: Tor (`socks5h`) | on, only if XvB enabled | `XVB_ENABLED=false` stops it |
| **XvB donation mining** (only while donating) | `na.xmrvsbeast.com:4247` | — | `performance`: direct; `balance`/`privacy`: ✅ Tor (per-pool `socks5`) | on while donating | explicit `xvb.tor` wins; `xvb.enabled: false` stops it entirely |
| Dashboard **XvB warm-standby pull** (#249) | the primary stack you named | nothing about you — the primary sees a **Tor exit**, not your IP | ✅ Tor (`socks5h`) for an onion or any source not provably private; only a private, loopback or link-local IP *literal* dials direct as a LAN hop (a hostname can't be proven private without DNS, so it rides Tor) | opt-in (`xvb.standby.source`; off until set) | unset `xvb.standby.source` to stop it |
| Dashboard **update check** (#224, plus the per-worker RigForge badge #596) | `api.github.com` | nothing about you | `performance`: direct; `balance`/`privacy`: Tor (`socks5h`) | **on** | `dashboard.check_for_updates: false` opts out of both; cached, fails silently offline |
| **Caddy** TLS (dashboard HTTPS) | local only | — | n/a — `tls internal`, **no ACME / no external CA** | on | clean (no egress) |
| **Telegram** bot (#121) | `api.telegram.org` | nothing about you | `performance`: direct; `balance`/`privacy`: Tor (`socks5h`) | **off** | opt-in; both the alert sends and the command poll follow the profile |
| Dashboard **Healthchecks** ping (#79) | `hc-ping.com` (or self-hosted) | nothing about you | `performance`: direct; `balance`/`privacy`: Tor (`socks5h`) | opt-in (set `healthchecks.ping_url`; off until set) | profile routing applies; an explicit `notifications.tor` value wins |
| Dashboard **price feed** (#520) | `api.coingecko.com` | nothing about you | `performance`: direct; `balance`/`privacy`: Tor (`socks5h`) | **off** | opt-in (`dashboard.energy.price_feed: true`); fetches the XMR + XTM spot prices every 15 min; fails silently, static config prices are the fallback |
| Dashboard **Tor egress probe** (#424) | `www.google.com/generate_204` and `www.cloudflare.com/cdn-cgi/trace` | No account identifier | Tor when auto-heal is enabled | **off** | `performance` disables auto-heal; `balance`/`privacy` govern it. The no-login path remains inactive until [#3166](https://github.com/p2pool-starter-stack/pithead/issues/3166) lands. |
| Dashboard **Tari explorer reference** (#2464) | `textexplore.tari.com` (or `tari.explorer_url`) | nothing about you | profile-controlled outbound request | **on** while Tari is local or remote | once an hour; a blank URL turns it off and a failed fetch contributes nothing to the verdict |
| **Webhook / ntfy** alert sinks (#380) | your configured URLs | alert texts | `performance`: direct; `balance`/`privacy`: Tor (`socks5h`) | opt-in (set `notifications.webhooks` / `notifications.ntfy.url`; off until set) | an explicit `notifications.tor` value overrides the profile |

`socks5h` (used for the XvB stats fetch) routes DNS resolution through Tor too, so the hostname isn't
resolved on the clearnet either. The host-networked dashboard reaches the bridge's Tor SOCKS at
`172.28.0.25:9050`.

A remote node given as a hostname (`monero.remote.host` or `tari.remote.host`) is the exception:
p2pool's socat bridge (above) only moves the TCP connection itself off the SOCKS5 proxy, so the
DNS lookup that turns that hostname into an IP still happens on the clearnet, via the container's
own resolver — same exposure as any of the closed clearnet DNS lookups above, but this one has no
toggle. Use an IP literal instead if that lookup itself is a concern.

The dashboard's egress panel classifies the alert-sink carve-out by what it can prove from the
config alone: with `notifications.tor: false`, the sinks show as **local** — not a counted leak —
only when every configured endpoint is a private or loopback IP literal, since such a POST never
leaves your network. A hostname can't be proven private without a DNS lookup, so a hostname
endpoint with Tor off counts as **clearnet**, a real leak.

The topology diagram moves a remote monerod or Tari node outside the host zone and shows both
gRPC/RPC hops to it without expanding the internal mesh. A private, loopback or link-local IP
literal draws as **LAN**: the hop leaves this machine but stays on your network, so it does not
expose your IP and is not counted as a leak. Any other IP literal draws as **clearnet** and is
counted. A hostname draws as **Unverified** because the diagram will not resolve it and create a
DNS egress on every render. A remote node never gets the local daemon's Tor P2P edge or initial-sync
edge; those describe a node this machine runs. Unverified is not counted as a proven leak, but it
makes the shared security summary warn instead of claiming all egress uses Tor.

The two **ingress** hops draw as **Incoming**: mining traffic into xmrig-proxy and HTTPS into
Caddy, with their sources grouped under **Clients**. This keeps client connections distinct from
the in-process hops marked **Local** without claiming where a client is or which interface accepted
it. The diagram is not a listener inventory:
the stratum bind is configurable, and RPC, ZMQ, and gRPC listeners can also be exposed through
their opt-in settings. Check the bind settings and host firewall for the actual exposure.

**LAN is a statement about exposure, not about encryption.** A remote-node hop is a plaintext
connection whichever way it draws, so the rows above still apply: anyone who can watch your local
network can read it. LAN means only that the traffic does not reach the internet.

---

## Build / setup-time egress

These run once, at install or `pithead apply`, and inherently reveal your IP to the host you
download from. They cannot be Tor-routed transparently, but they are integrity-pinned so a network
attacker can't substitute what you receive.

| What | Destination | When |
|---|---|---|
| Source clone / release bundle | `github.com` | install / update (`git checkout vX.Y.Z` or downloading the release bundle) |
| Component binaries (monerod / p2pool / xmrig-proxy) | `downloads.getmonero.org`, `github.com` | **image build only** — verified against a published **SHA256** / checksum. A release install *pulls* prebuilt images instead, so it never runs these. |
| Container images | **`ghcr.io`** (the `pithead-*` images, #44), `quay.io` (Tari), Docker Hub (caddy, socket-proxy) | image **pull** on a release install / `pithead upgrade`, or build from source. All pinned by **`@sha256:` digest** (#135). |

Mitigation: run the install/build behind a VPN or with `torsocks`, or pre-pull the images and clone
on another machine and copy them over. The downloads are pinned (SHA256 + image digests), so the
risk is the one-time IP disclosure, not tampering.

---

## Profile-controlled routing

The `performance`, `balance`, and `privacy` profiles coordinate node sync, P2Pool peering, and
dashboard outbound services. An absent profile means `balance`. Explicit governed settings win over
the profile, and selecting a profile clears its governed overrides. Inbound onion peering remains
separate from outbound routing.

### Performance

Local Monero and Tari nodes keep using clearnet after initial sync, including Monero transaction
broadcasts. P2Pool, XvB, notifications, release checks and price feeds dial directly. Peers and
service providers see the host IP. The egress firewall and Tor auto-heal are off by default.
Inbound onion services remain available independently of outbound routing.

### Balance

Local node sync and ongoing outbound traffic use Tor. P2Pool may reach clearnet peers through
Tor exits. The egress firewall is on. Rigs need neither a stratum password nor worker API token.
Tor auto-heal defaults on; without its host control channel it is inactive, which status reports.

### Privacy

Balance applies, with P2Pool restricted to onion peers. A source-restricted relay accepts only
connections from the Tor service and forwards only the P2Pool peering port to its loopback
listener. No bridge port is published to the host or LAN; neither RPC nor stratum is forwarded.
An explicit clearnet P2Pool override removes onion-only mode and its relay.

A stratum password and worker API token are generated and retained in the owner-only environment
file. Update every rig to match. Stratum TLS is available on the same port and remains optional
per connection. [Configuration](configuration.md#profiles) lists the governed defaults and overrides.

What Tor costs you (measured): a 5-day interleaved benchmark on `mini` (#256, full
[methodology + data](benchmarks/tor-vs-clearnet.md)) puts the price of routing P2Pool over Tor at
roughly 10 % of mining yield (−11 % reward share / yield-efficiency vs clearnet, just above the run's
noise floor). The cause is pure share-propagation latency: there were zero extra rejected shares and
no measurable Tor CPU overhead. The loss is shares arriving late enough to land as uncles. We keep
Tor the default anyway, because not leaking your home IP to the P2Pool network is the point and ~10 %
is a modest, opt-out-able price. The cost is largest on the smaller/faster sidechains (where your
share of the chain is biggest) and negligible on `main`.

### P2Pool outbound peers (#165)

P2Pool advertises its onion for inbound peers through a source-restricted Tor service bridge on the
existing P2Pool peer port. The bridge does not publish a host or LAN port and never forwards RPC or
stratum. `balance` and `privacy` route outbound sidechain peers through Tor; `performance` keeps
clearnet peering for yield.

The Tor-routed profiles add `--no-dns` (#2496). The SOCKS proxy does not cover P2Pool's seed-node lookup:
without the flag it looks up `seeds-mini.p2pool.io` (or the `main`/`nano` equivalent) in DNS
on every peer-list load, which tells your ISP or resolver that the address runs P2Pool.
With it, P2Pool makes no DNS queries and builds its peer list from its saved `p2pool_peers.txt`, its
built-in onion seed nodes and any `--addpeers`. `p2pool.clearnet: true` drops `--no-dns` along with
the SOCKS flags, so a clearnet node still bootstraps from the DNS seeds.

For a governed override, set `p2pool.clearnet: true` in `config.json` and re-run `./pithead apply`.
The default-on egress firewall then exempts only P2Pool's container from its
IPv4 public-dial block; turning the flag off and applying removes that exemption. P2Pool peers see
your home IP. The `privacy` profile passes `--no-clearnet-p2p` for onion-only outbound peers. An
explicit `p2pool.clearnet: true` override wins and restores clearnet peers; inbound onion peering is
unchanged.

Trade-off (measured): Tor adds latency to share propagation, costing ~10 % of yield on `mini` (#256,
the loss is uncles/late shares, not rejects; see the box above), and `--no-clearnet-p2p` shrinks your
peer set to onion-only. The Tor-by-default flip was gated on that benchmark, which is why it's a v1.1
change (#165), not a v1.0 default. The opt-out works with the default egress firewall on (#2790).

### XvB donation mining (#166)

When the optimizer donates to XMRvsBeast (XvB), it points the proxy at `na.xmrvsbeast.com:4247`.
`balance` and `privacy` route that connection through Tor; `performance` uses direct egress. XvB
stats, raffle registration, and winners requests follow the same profile routing.

An explicit `xvb.tor` value overrides the profile. With `xvb.tor: false`, the donation connection
dials direct. The firewall exempts only xmrig-proxy while XvB is enabled and this choice is active;
switching Tor back on or disabling XvB removes the exemption at apply. The XvB pool sees your
home IP while donating. To stop the egress entirely instead, disable XvB (`"xvb": { "enabled": false }`), which also
stops the profile-routed stats fetch.

> NOTE: the xmrig-proxy dev-fee `--donate-level` is pinned to `0` by default (`proxy.donate_level`,
> rendered explicitly per #173) and does not ride the XvB pool's `socks5`, so if you set it above 0,
> that dev-fee traffic goes clearnet. Keep it at `0` for a fully Tor runtime.

---

## Profile-controlled initial sync

Tor is the default for `balance` and `privacy`. The `performance` profile keeps local Monero and
Tari nodes on clearnet for initial sync and ongoing operation, avoiding Tor's bandwidth and latency
cost. Set either flag explicitly to override the profile for a local node.

Per-component flags in `config.json`, both `false` by default:

```jsonc
"monero": { "clearnet_initial_sync": false },
"tari":   { "clearnet_initial_sync": false }
```

Set the one(s) you want to `true` and run `./pithead apply`. Keep the egress firewall on. Monero and
Tari sync independently, so you can enable either, both, or neither. With `monero.mode: remote` or
`tari.mode: remote`/`off`, the corresponding sync flag is forced to `false` because there is no local
daemon to sync.

NOTE: both flags act on the bundled daemons only. With `monero.mode` or `tari.mode: remote` there is
no local daemon here to sync, so the matching rendered flag is false.

### What it changes

| | `balance`/`privacy` | `performance` or explicit clearnet override |
|---|---|---|
| **Monero** P2P | over Tor (`proxy=172.28.0.25:9050`) | **direct to clearnet seed nodes** (proxy line dropped), `out-peers` 48 → **32** + P2Pool v4.18's recommended **priority nodes** (`p2pmd.xmrvsbeast.com`, `nodes.hashvault.pro`) for fast, reliable sync |
| **Monero** tx broadcast | over Tor (`tx-proxy=`) | direct under Performance; still Tor for an explicit first-sync override |
| **Tari** transport | Tor SOCKS (`type = "socks5"`) | **TCP** (`type = "tcp"`) |
| **Tari** seeds | onion `peer_seeds`, `dns_seeds = []` | **`dns_seeds = ["seeds.tari.com"]`** (onion seeds are unreachable without Tor), onion `public_addresses` dropped |

### The privacy trade-off (threat model)

What is exposed while a flag is on: your host's IP address, to the P2P network of the enabled chain,
i.e. "this IP is running a Monero/Tari node." A few DNS lookups also happen over clearnet during the
window: for Monero, the two P2Pool-recommended priority-node hostnames (`p2pmd.xmrvsbeast.com`,
`nodes.hashvault.pro`); for Tari, `seeds.tari.com` (to the configured resolvers `1.1.1.1` /
`8.8.8.8` / `9.9.9.9`) to discover clearnet peers. This is the same exposure as any ordinary clearnet
node, which is exactly what this window temporarily is.

What is *not* exposed:

- Your wallet addresses / payouts: there is no wallet activity during a sync.
- Under Balance or Privacy with an explicit first-sync override, Monero transaction broadcasts
  retain `tx-proxy=tor`. Performance removes that proxy for ongoing operation.
- Nothing about *what* you mine, only that an IP runs a node.

That's the same exposure as running any ordinary (non-Tor) full node, scoped to the sync window. For
a privacy-first deployment it's still a real disclosure, which is why it is off by default and must
be explicitly opted into.

### The egress firewall stays on

The [fail-closed egress firewall](#enforced-fail-closed-not-just-configured-270) admits direct IPv4
egress from the selected node's own container during first sync, from P2Pool when
`p2pool.clearnet` is true, and from xmrig-proxy when XvB is enabled with `xvb.tor` false.
Every other container stays restricted, and the IPv6 backstop remains in place.
The host checks that the node's live `ACCEPT` is scoped to its address and precedes the subnet's
blocking `DROP`; a broad or later exception does not count as active. The chosen node gets
clearnet peers without opening the entire stack's egress.

### Profile persistence

The selected profile persists across restarts and `apply`. An explicit sync flag persists as an
override until the operator selects a profile or changes the flag again. Remote modes force the
corresponding sync flag false because they have no local daemon.

### Exposure is loud and always-visible

The active state is surfaced in four places, so it can't be enabled by accident or missed:

- `./pithead apply` prints a `⚠`-flagged, disruptive-change confirmation describing exactly what
  becomes exposed before it recreates the daemon.
- `./pithead status` names the profile, or Custom when an explicit governed value differs.
- Apply previews name the profile changes and the exposure they introduce before recreating a daemon.

---

## Local trust boundary & known limitations

Everything above is about network egress, what leaves the host. On the host itself, the stack assumes
the local machine and the private Docker bridge are trusted, which is the right model for a
single-purpose appliance. One consequence is worth recording explicitly:

- **The monerod RPC credential appears in the p2pool container's process arguments (#57).** p2pool
  accepts the monerod RPC login (`--rpc-login`) only as a command-line argument; it has no
  environment-variable or config-file equivalent, so the username/password are visible in the p2pool
  process's argv to any local process that can read it (`ps`, `/proc/<pid>/cmdline`). This is
  local-only (never remotely reachable) and the credential is an auto-generated random secret
  guarding the restricted (read-only, public-safe) RPC listener that by default is bound to localhost
  plus the Docker bridge, not the LAN (set `monero.rpc_lan_access: true` to expose it, in which case
  the credential matters more). Moving it off argv isn't possible without removing RPC authentication
  (a worse trade-off, it's defense-in-depth on the internal path) or an upstream p2pool change, so
  it's accepted as a known limitation rather than fixed. Practical guidance: on a single-user
  appliance this is a non-issue; if you co-host the stack on a machine shared with other local users,
  treat the monerod RPC credential as visible to them and prefer a single-purpose host for stronger
  isolation.
- **A remote node sits inside your trust boundary.** With `tari.mode: remote`, p2pool's merge-mine
  gRPC is plaintext and unauthenticated end to end: p2pool cannot verify that the block template it
  gets back actually pays `tari.wallet_address`, so the node's operator — or anyone on the network
  path — can substitute a different payout, and nothing in the stack would catch it. A remote Monero
  node is the milder version of the same shape: it decides what chain state you mine on. Use nodes
  you run yourself or trust, on your LAN or over WireGuard. Only Tari yield is exposed this way;
  Monero mining runs on a separate path. See
  [Configuration › Trust boundary](configuration.md#trust-boundary).

## Maximum-privacy checklist

- [ ] Keep `:3333` off the public internet: firewall it to your LAN, set `p2pool.stratum_bind`,
  and/or require a `p2pool.stratum_password` (`pithead doctor` flags public-IP exposure).
- [ ] Select the `privacy` profile, or leave `p2pool.clearnet` explicitly false, to keep P2Pool
  outbound peers onion-only. Inbound onion peering uses its separate source-restricted bridge.
- [ ] Set `xvb.enabled: false` if you don't want any XvB egress.
- [ ] Use `balance` or `privacy` to keep local node P2P on Tor; use `performance` when persistent
  clearnet node operation is intentional.
- [ ] Run the initial install/build behind a VPN or `torsocks`.
- [ ] Use `balance` or `privacy` for Tor-routed Telegram, Healthchecks, webhook, and ntfy delivery;
  explicit `notifications.tor` overrides the profile.
- [ ] Run `./pithead doctor`; it surfaces the public-IP exposure check among its diagnostics.

---

See also: [Architecture › Privacy by design](architecture.md#privacy-by-design) ·
[Connecting Miners › Firewall](workers.md#firewall) · the privacy-egress epic (#160).
