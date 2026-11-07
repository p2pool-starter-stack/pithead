# Getting Started

Choose a deployment, connect a worker, and check accepted mining work with the released Pithead stack.

## Choose your next action

The **coordinator** runs P2Pool, the proxy and dashboard, with local or remote nodes. A **worker**
runs XMRig and sends work to that coordinator; it needs no chain storage or payout wallet secrets.

| Starting point | Next action | Supported platform and resources | What changes |
|---|---|---|---|
| An existing XMRig worker and a running coordinator | [Connect the miner](#6-connect-your-miners). RigForge is optional. | Keep the miner's supported OS and RandomX resources; allow network access to the coordinator's advertised stratum endpoint. No coordinator-sized disk is needed on the worker. | Change the miner's pool settings; no OS install or disk imaging. |
| An existing host for the coordinator | Follow [prerequisites](#1-prerequisites) and the DIY setup below. | Ubuntu Server 24.04 LTS, x86-64, 4+ cores, 16 GB+ RAM; AVX2 advised. Plan 600 GB+ SSD with both nodes local, about 370 GB with Tari remote or off; [other node arrangements](hardware.md#running-a-node-elsewhere) have different budgets. | Keep the OS and disks. Setup writes config, offers dependencies and host HugePages tuning, provisions Tor, then offers to start the stack. |
| A machine to dedicate to the appliance | Follow [the appliance guide](appliance.md#what-you-need), verify the image, then select the role and disk there. | x86-64 UEFI, wired ethernet, a 16 GB+ USB stick and a second computer with a browser. A coordinator needs 16 GB+ RAM and the SSD budget above plus OS partitions; worker-only uses [worker sizing](hardware.md#choose-the-arrangement). | Writing the image erases the selected USB stick. Installing erases the selected target disk. Back up first and verify both selections. |

For a new worker, use [RigForge's supported installation](workers.md#new-to-mining-start-with-rigforge)
or the appliance's **RigForge** role. Released RigForge supports Ubuntu 22.04+ or Debian 12
on x86-64 with AVX2; allow about 2.3 GB free RAM for RandomX fast mode plus OS headroom and
about 2 MB L3 cache per mining thread. Check its
[worker requirements](https://github.com/p2pool-starter-stack/rigforge/blob/v1.18.0/docs/hardware.md#requirements).
For a coordinator that also mines, read
[local-worker setup](workers.md#mine-on-the-stack-host-itself) before enabling it: CPU, RAM,
cache and memory bandwidth are shared with the nodes and other applications. Coordinator-only
leaves mining to separate workers. See [role sizing](hardware.md#choose-the-arrangement).

Shared-host resource profiles, pressure-aware stop/resume and measured coexistence guidance are
planned in [rigforge#577](https://github.com/p2pool-starter-stack/rigforge/issues/577),
[rigforge#578](https://github.com/p2pool-starter-stack/rigforge/issues/578) and
[rigforge#579](https://github.com/p2pool-starter-stack/rigforge/issues/579). Current setup does not
detect idle capacity and schedule mining around other workloads. Use the
[manual controls](#8-limit-stop-disable-or-remove) below.

The remaining installation steps are for the DIY coordinator. Existing miners can go directly
to connection and [first-work checks](#7-check-progress-and-first-accepted-work); appliance users
return to those checks after completing the appliance setup.

> **TL;DR**
>
> ```bash
> curl -fsSL https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz | tar xz
> cd pithead
> ./pithead setup
> ```
>
> Have a Monero payout address ready; Tari merge-mining is an optional beta, off unless you say yes, and has its own payout address.
> Let it run, then open the dashboard at `https://<your-hostname>`.

---

## 1. Prerequisites

| Requirement | Recommendation |
|---|---|
| Operating system | Ubuntu Server 24.04 LTS is the supported platform. Other Linux distributions may work but aren't supported. macOS is deprecated as of 2026-09-10 and is not tested; the installer refuses it. |
| CPU | A processor with AVX2 support for RandomX performance. |
| RAM | 16 GB minimum with HugePages enabled (~6 GB is reserved for RandomX); 32 GB for a full node or long uptimes. |
| Disk | A Monero node synced from genesis with pruning enabled consumed 285.8 GB in September 2026. Buy at least a 600 GB SSD with both Monero and Tari local, in either prune mode, or 370 GB with Tari off (the wizard default) or remote. Both chains keep growing, so a 2–4 TB drive is the set-and-forget choice. Running either node on another machine drops its share — see [Running a node elsewhere](hardware.md#running-a-node-elsewhere). |
| Software | Docker Engine, Docker Compose V2, `jq`, `openssl`, and `python3`. |

> 📐 Sizing guidance for the stack host — minimum vs. recommended specs, plus ways to run leaner —
> is in **[Hardware Requirements](hardware.md)**. Miner specs live in
> [RigForge](https://github.com/p2pool-starter-stack/rigforge).

> 🔎 `setup` checks this for you. Before it starts anything, `./pithead setup` runs a best-effort
> pre-flight on free disk and total RAM. If free disk is below the enforced budget (528 GiB
> with both nodes local) or RAM is below the 16 GB floor, it prints a warning. The disk figure follows the node
> modes you configured; the 16 GB RAM warning fires regardless. It never blocks setup, so you can
> proceed on a smaller host at your own risk. See **[Hardware Requirements](hardware.md)**.

You don't have to install the software dependencies yourself. `setup` checks for them and, on
Ubuntu, offers to install anything missing. To do it manually:

```bash
sudo apt update && sudo apt install -y jq docker.io docker-compose-v2 openssl python3
```

On an unsupported OS, or if dependency detection misfires on an unusual setup, run setup with
`--skip-deps` to bypass the check entirely.

---

## 2. Get the code

Download the latest release. This pulls the published, tested images (no local build), so the
dashboard shows the real version and the update-checker works:

```bash
curl -fsSL https://github.com/p2pool-starter-stack/pithead/releases/latest/download/pithead.tar.gz | tar xz
cd pithead
```

Leave `config.json` absent to use the setup wizard. Have a Monero payout address ready, and a
Tari payout address if you enable merge-mining (Tari wallets are sometimes labeled Minotari).
For a manual configuration, copy `config.minimal.json` or `config.reference.json` to `config.json`
and edit it before setup. The minimal file uses the shared wizard defaults for a new install,
including Tari off; the reference file retains legacy absent-key values to preserve existing
configs.

### Alternative: install from the APT repository

Ubuntu 24.04 on amd64 can install and update Pithead through apt. The repository holds the
latest stable release only; release candidates and older versions stay on the
[releases page](https://github.com/p2pool-starter-stack/pithead/releases).

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://p2pool-starter-stack.github.io/pithead/pithead.asc | sudo tee /etc/apt/keyrings/pithead.asc >/dev/null
gpg --show-keys --with-fingerprint /etc/apt/keyrings/pithead.asc
```

Compare the printed fingerprint with
[`packaging/apt/fingerprint`](https://github.com/p2pool-starter-stack/pithead/blob/main/packaging/apt/fingerprint)
in the repository before you continue. Then add the source and install:

```bash
sudo tee /etc/apt/sources.list.d/pithead.sources >/dev/null <<'EOF'
Types: deb
URIs: https://p2pool-starter-stack.github.io/pithead/
Suites: ./
Architectures: amd64
Signed-By: /etc/apt/keyrings/pithead.asc
EOF
sudo apt update
sudo apt install pithead
sudo pithead setup
```

The package keeps its pristine program tree in `/usr/share/pithead` and copies it to
`/var/lib/pithead`, where `config.json`, `.env` and the stack's data live. Run every `pithead`
command through `/usr/bin/pithead`, which re-runs itself with `sudo` when needed. The same
`.deb` is attached to each GitHub release with a cosign signature (`pithead_X.Y.Z_amd64.deb.sig`); if
you install it by hand, verify it first with `cosign verify-blob --key cosign.pub --signature
pithead_X.Y.Z_amd64.deb.sig --insecure-ignore-tlog=true pithead_X.Y.Z_amd64.deb` (the key is
[`cosign.pub`](https://github.com/p2pool-starter-stack/pithead/blob/main/cosign.pub) in the
repository), then run `sudo apt install ./pithead_X.Y.Z_amd64.deb`.
An APT install has no in-app updater: see
[Operations › Updating an APT install](operations.md#updating-an-apt-install).

### Alternative: build from source

To build the images locally instead of pulling the published ones, e.g. to develop or modify the
stack, clone the repo. pithead sees the `build/` context and builds locally, tagging the images `:dev`
(the dashboard badge then reads `dev · <branch> @ <commit>` instead of the release version):

```bash
git clone https://github.com/p2pool-starter-stack/pithead.git
cd pithead && make
```

Release archives already include the generated `pithead` executable. Git clones keep only its
numbered sources, so `make` builds the executable before the first `./pithead` command.

> Changed your mind later? You can convert a clone to the published images in place. See
> [Switching a source checkout to release images](operations.md#switching-a-source-checkout-to-release-images).

#### Interrupted source build

If setup is interrupted while building Tor, it returns a nonzero status and retains `config.json`.
A Tor build or startup failure preserves Docker's error output and exit status, names the failed
phase and points here. Keep the configuration; the next `./pithead setup` uses it again.

The BuildKit error `failed to stat active key during commit: snapshot ... does not exist: not found`
is a Docker build-state failure, not evidence that `config.json` is damaged. Inspect the daemon,
containers and build cache before retrying:

```bash
docker info
docker ps -a
docker system df
docker buildx du
sudo journalctl -u docker.service -n 100 --no-pager
```

The build-cache command requires the Buildx plugin; see [Docker's disk-usage reference](https://docs.docker.com/reference/cli/docker/buildx/du/).
The journal command applies to Linux hosts running Docker under systemd. Review logs locally;
they can contain private configuration. Then retry from the unchanged checkout:

```bash
./pithead setup
```

Pithead does not restart Docker or prune its cache. If the same snapshot error persists, arrange
operator recovery after inspecting the logs and other workloads. A Docker daemon restart affects
other containers on the host; it is an explicit operator action, not a default setup repair.
Do not delete `config.json`, containers, volumes or broad build caches to retry setup.
Keep destructive recovery experiments on a disposable isolated host. A retry that succeeds only
after operator assistance must be recorded as assisted recovery, not an unattended retry pass.

---

## 3. Run setup

```bash
./pithead setup
```

Setup walks through five stages. It's interactive on the first run and safe to re-run later.

1. **Dependency check.** Verifies Docker, Docker Compose, `jq`, `openssl`, and `python3` are present. On
   Ubuntu it offers to `apt install` anything missing; on other systems it tells you what to
   install. Skip with `--skip-deps`.

2. **Interactive configuration.** Asks only what only you can answer, in two short stages, then
   fills in the rest and writes a minimal `config.json`, locked down to owner-only (`chmod 600`).
   Use a dedicated Monero mining wallet: P2Pool payout addresses are public
   ([P2Pool's guidance](https://github.com/SChernykh/p2pool/releases/tag/v4.18.1)).
   - **Required:** your Monero wallet address; whether you're running a local Monero node (the
     default — the stack runs its own) or connecting to a remote one, with a local node's RPC
     credentials auto-generated; and your P2Pool pool tier (`main`/`mini`/`nano` — pick low if
     you're not sure, a high-hashrate default silently starves a small rig of shares). An
     dashboard login, generated on Enter and printed once; enter `none` to opt out.
   - **Merge-mine Tari? (beta)** Three answers: no, run the bundled Tari node here, or use a Tari
     node you already run. Tari runs on pre-release upstream software, so Enter means no. Yes
     downloads and syncs a Tari chain over Tor, which takes days. A yes asks for your Tari payout address, and "a node I already run" asks
     for its host and gRPC port — see [Remote Tari node](configuration.md#remote-tari-node). A no
     asks nothing further and stores no Tari address; nothing merge-mines and no Tari node runs.
     The wizard writes `tari.mode` explicitly whichever way you answer, so the answer survives.
     The one exception is a reinstall that keeps its data: when `./data/tari` already holds half
     the Tari budget or more, Enter keeps the bundled node on, so it does not silently drop
     merge-mining. The wizard prints the free space it measured against the whole-stack budget
     (the bundled Tari node adds 200 GiB to Monero's) for anyone who says yes. A yes on a new
     install also writes `dashboard.tari_required: false`, so Tari cannot hold or reject Monero
     mining. Changeable later from the
     dashboard's Configuration view, or by editing `tari.mode` and running `./pithead apply`.
   - Once the config is written, setup asks one more thing: the hostname you'll use to reach the
     dashboard in a browser. Enter accepts this machine's hostname.
   - **A few more, Enter for the default:** a faster clearnet initial sync (hours instead of days,
     for every local chain, exposing your IP address to the Monero network and, when Tari runs
     locally, the Tari network until initial sync finishes) instead of
     the private Tor default; reaching the dashboard from outside your LAN over Tor; Telegram alerts; and
     whether this machine should also mine with its spare CPU (a co-located RigForge worker).
   - XvB is off and is not asked; enable it later from the Configuration view.
   - Everything else — ports, energy pricing, per-worker overrides, and more — keeps
     its documented default; the wizard prints a pointer to `config.json` and
     [Configuration](configuration.md) at the end for anyone who wants it.

3. **Tor provisioning.** Brings up the Tor service and waits for the hidden-service (onion)
   addresses: P2Pool always, plus Monero and Tari for whichever of those nodes runs locally. A node
   in remote mode gets no inbound onion — it accepts its own peers where it runs.

4. **Kernel optimization (Linux only).** Configures HugePages for RandomX performance. Making
   HugePages persistent adds `/etc/default/grub.d/zz-pithead-hugepages.cfg` and requires a reboot.
   Setup preserves existing boot arguments, including cloud console settings, and verifies the
   generated kernel entries after `update-grub`. It repairs previous Pithead reservations on
   re-run; a new or unrecognized reservation requires confirmation. An unchanged setup on a host
   already booted with the verified flags continues to Start without requesting another reboot.
   Skip this stage with `--skip-optimize`.

5. **Start.** Once everything is provisioned, setup offers to start the stack.

> If you enabled persistent HugePages, reboot before mining. After the reboot, start the stack
> with `./pithead up`.

### Setup flags

| Flag | Effect |
|---|---|
| `--skip-optimize` | Skip the kernel/GRUB HugePages tuning (useful on non-Linux hosts or when you tune the kernel yourself). |
| `--skip-deps` | Skip dependency detection and installation. |

---

## 4. First boot: the node syncs

A fresh setup leaves Tari off unless you enable it. A local node downloads and verifies its
chain; a remote node syncs where it runs. Mining waits for Monero, and also for Tari when
`dashboard.tari_required` is true. The new-install wizard writes that setting false when you
opt into Tari, so Tari can catch up in the background while Monero mining starts. Manual configs
inherit different reference defaults; check [the sync gate](configuration.md#configuration-reference).

The first start prints `The miner is held until the initial sync finishes for Monero, then starts
automatically.` When Tari is required, the note names `Monero and Tari` instead. Later restarts
do not repeat the note.

Watch the dashboard's Sync Mode and node cards. `./pithead status` prints required-chain progress
while mining is held; passive Tari sync is visible on the dashboard and in its node log:

```bash
./pithead status
```

Follow only a node this coordinator actually runs:

```bash
./pithead logs monerod
```

For a local Tari node, use `./pithead logs tari`. First sync depends on hardware, disk and network;
progress is not a payout clock. Once the required nodes are ready, P2Pool and the proxy start.
[Dashboard sync states](dashboard.md#sync-mode) explain readiness and recovery waits.

> Already have a synced Monero node? You can skip most of the initial sync by pointing the stack
> at your existing blockchain data, or by connecting to a remote node. See
> [Reusing an existing node](configuration.md#reusing-an-existing-node). The same holds for Tari:
> point `tari.data_dir` at an existing Minotari chain, or set `tari.mode: remote` to merge-mine
> against a node on another machine — see [Remote Tari node](configuration.md#remote-tari-node).

> Sync crawling over Tor? The default routes the first sync over Tor for privacy, which is slow.
> You can opt into a faster clearnet initial sync for Monero and/or Tari while the egress firewall
> stays on. It takes hours instead of days, exposes your IP to that chain's peers during the sync,
> and switches each node back to Tor automatically when it finishes; the warning stays until the host verifies the live daemon and firewall. Read the
> trade-off first:
> [Optional clearnet initial sync](privacy.md#optional-clearnet-initial-sync-off-by-default).

---

## 5. Open the dashboard

The dashboard is served over HTTPS by Caddy:

```
https://<your-hostname>
```

`<your-hostname>` is the host you set during setup (the script prints the exact URL when it
starts the stack). Caddy uses a local certificate authority (`tls internal`).
[Verify and trust its root CA](configuration.md#exposing-the-dashboard-safely) to avoid repeated
browser warnings after certificate renewal. Prefer plain HTTP on your LAN? Set
`dashboard.secure: false` in `config.json` and run `./pithead apply`.

---

## 6. Connect your miners

Use the coordinator's **Connect a miner** card or the connection details printed by `setup`,
`up` or `apply`. Copy the advertised pool URL, the stratum password if set, and the certificate
fingerprint when TLS is enabled. Port `3333` is the default; a loopback bind accepts only local
workers. Follow [Connecting Miners](workers.md#already-have-miners-connect-them) for miner settings,
[authentication](workers.md#authentication) and LAN/TLS requirements. Keep credentials out of
screenshots and support posts. Do not place a payout wallet address in the miner configuration.

Existing XMRig needs no RigForge installation, management token or descriptor to send work.
Management is a separate opt-in:

- Direct telemetry needs a reachable read API with the matching port and read credential, if
  configured. A failed API probe does not prevent proxy-derived worker statistics. Restrict both
  read and control APIs to a trusted isolated LAN or protected tunnel; the read API may be open by
  default. Configure read authentication before allowing untrusted clients network access;
  authentication alone does not encrypt HTTP.
- Managed RigForge changes require the rig's enabled control API, its permitted coordinator,
  control port and write-capable token, plus Pithead's authenticated dashboard control channel.
  Keep read probe credentials separate from the control token. Use an isolated trusted LAN or
  protected tunnel: the RigForge control API uses plaintext HTTP.
- **Adopt this rig** can append a new descriptor after host-side target validation and typed
  `APPLY`. It cannot repoint, reorder or remove an existing descriptor. Saving a descriptor is
  followed by the next successful telemetry poll; it is not proof that work was accepted.
  See [Worker Inspect](dashboard.md#worker-inspect) and
  [per-worker prerequisites](workers.md#per-worker-overrides).
  Broader descriptor editing belongs to [pithead#912](https://github.com/p2pool-starter-stack/pithead/issues/912);
  the enrollment redesign belongs to [pithead#2533](https://github.com/p2pool-starter-stack/pithead/issues/2533).

## 7. Check progress and first accepted work

| Checkpoint | Where to check | What it proves |
|---|---|---|
| Setup and sync | `./pithead status`, Sync Mode and node cards | Required services and chains are becoming ready. Healthy containers alone do not prove mining. |
| Worker connected | **Workers Alive** and its hashrate | The proxy sees the worker. Connection alone does not prove accepted work or management access. |
| Accepted miner work | The worker's **Accepted** count and **Proxy totals** advance; inspect rejected/invalid counts too | Work is being accepted on the mining path. These low-difficulty miner shares are distinct from P2Pool sidechain shares. |
| P2Pool payout eligibility | **Shares in Window** above zero in the selected sidechain | A P2Pool share is in the current PPLNS window. Payment still depends on the pool finding a Monero block while that share is eligible. |
| Confirmed reward | Your wallet's incoming payouts, or the optional dashboard **Confirmed on-chain** totals | A reward actually arrived. Hashrate and expected earnings are estimates, not confirmation. |

Check successive fresh readings rather than a single screenshot; counters can reset when the proxy
restarts. If accepted work does not advance, use [worker statistics](dashboard.md#workers-alive)
and [troubleshooting](operations.md#troubleshooting) before changing tuning.

Choose `p2pool.pool` for your hashrate: `main` for large farms, `mini` for typical home rigs,
`nano` for a low-power rig. See [pool selection](configuration.md#configuration-reference).
A smaller sidechain improves share frequency; it promises no payout date. An empty PPLNS window
is different from a disconnected worker or rejected miner work. P2Pool payouts vary, and optional
Tari merge-mining is solo and more variable; neither has a first-payout deadline.

Use a [dedicated Monero mining wallet](#3-run-setup), since P2Pool payout addresses are public.
[Dashboard payout confirmation](dashboard.md#payout-confirmation) is optional, needs the matching
private view key and a local node, and does not need a spend key or seed. Keep wallet secrets off
workers. Read [privacy](privacy.md), [proxy fees and XvB donation settings](configuration.md#configuration-reference),
[the miner donation floor](workers.md#per-worker-overrides) and [encrypted backups](operations.md#backups).
No hashrate or accepted-share count establishes profit; electricity, fees and actual rewards differ.

## 8. Limit, stop, disable or remove

- **Limit a worker:** use your miner's released thread controls. For RigForge, follow its released
  [thread ceiling](https://github.com/p2pool-starter-stack/rigforge/blob/v1.18.0/docs/configuration.md#configuration-reference). A thread count is not an enforced CPU percentage or memory budget;
  leave headroom for RandomX and other workloads. RigForge's dedicated-host tuning can alter
  HugePages, GRUB, MSR and the governor; review [local-miner ownership](workers.md#mine-on-the-stack-host-itself).
- **Stop mining:** stop the miner on each worker, including any local worker. Stopping the
  coordinator alone can send workers to their configured backup pools, where mining continues.
- **Stop or disable a DIY RigForge worker:** from its installed kit, run `sudo ./rigforge.sh stop`.
  Run `sudo ./rigforge.sh disable` to prevent boot startup; use both when you want it stopped now
  and after reboot. `sudo ./rigforge.sh start` starts it again and `sudo ./rigforge.sh enable`
  restores boot startup. Review the released [service commands and uninstall](https://github.com/p2pool-starter-stack/rigforge/blob/v1.18.0/docs/operations.md#commands)
  before removing a worker; these commands do not remove the appliance OS.
- **Stop a DIY coordinator:** run `./pithead down`; run `./pithead up` to start it again.
  This preserves its configuration and chain data.
- **Disable the appliance's local miner:** set `local_miner.enabled` false in Configuration and
  apply. On DIY this switch does not own the RigForge service; stop or disable it through RigForge.
- **Remove a DIY coordinator:** back up first, then follow
  [`./pithead uninstall`](operations.md#what-uninstall-removes). It keeps config, chains, Tor data,
  dashboard history and backups, but removes derived secrets and view-only wallet volumes.
  Retained config and backups still contain secrets, including view keys and control credentials.
  Securely copy them to storage you control, then erase retained sensitive files separately before
  transferring or decommissioning the host. Review retained data and host tuning before deleting
  anything further.
  Removing the appliance OS requires a deliberate replacement OS install; do not use the DIY
  uninstall instructions as an appliance disk-erasure procedure.

## Next steps

- [Configuration](configuration.md) — fine-tune the stack, reuse an existing node, or switch
  P2Pool sidechains.
- [The Dashboard](dashboard.md) — understand Sync Mode and every panel of the live view.
- [Operations & Maintenance](operations.md) — upgrades, backups, and troubleshooting.
