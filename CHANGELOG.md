# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/dev/releasing.md`](docs/dev/releasing.md).

## [Unreleased]

## [2.0.0] - 2026-10-03

### Upgrading from 1.20.x

- Upgrading from 1.x.x is best-effort; a fresh setup may be required.

- Take `./pithead backup --with-chains` before upgrading.
- Leave free space for the Tari migration: both database copies occupy the data volume at its
  peak. The upgrade requires the current `data.mdb` size plus 5 GiB free.
- Tari reads "loading" for about 2.5 hours during its first-start migration. Do not stop, restart
  or `apply` the stack until the migration finishes.
- If `tari.mode` is `remote`, upgrade the serving node to v6.0.1-pre.0 before this stack.
- The node and wallet database migrations are one-way. There is no way back to 1.x Tari.

Pithead 2.0.0 is the first release of **Pithead OS**, the appliance: a bootable image that
installs itself on a machine you dedicate to it, is set up from a browser, and updates as one
signed image that goes back to the previous version on its own when an update does not boot.
The Docker-Compose install (the DIY path) ships in the same release, with the same stack, the
same dashboard and the same configuration. Entries below apply to both channels unless they say
otherwise. The appliance guide is [`docs/appliance.md`](docs/appliance.md).

### Tari / P2Pool

- Tari outage alerts now describe the required policy and actual worker rejection state.
  Optional Tari keeps mining Monero; recovery claims readmission only after workers were
  rejected and the proxy successfully restarted (#3119).

- **Tari v6.0.1-pre.0 and P2Pool 4.18.1, upgraded together
  ([#1129](https://github.com/p2pool-starter-stack/pithead/issues/1129)).** The Tari 6.0 hard
  fork activates at mainnet block **350,000**; a node on an older version forks off the
  network at that height. P2Pool 4.18.1 changes how it sends Tari merge-mined work and requires a
  Tari node on 6.0.0 or newer, so the two move as one pair. The node and console wallet images now
  come from `ghcr.io/tari-project`, pinned by digest to the `v6.0.1-pre.0-mainnet` indexes: a
  6.0.0 node on a database migrated from 5.3.1 rejects canonical block 350,008 as below target
  difficulty and stays on a dead fork, and 6.0.1-pre.0 carries the upstream fix
  ([#2604](https://github.com/p2pool-starter-stack/pithead/issues/2604),
  [tari#8046](https://github.com/tari-project/tari/pull/8046)). Pre-2.0.0 installs are off the
  canonical chain until they upgrade.
  - **The first start migrates the Tari database, and there is no way back.** The node runs a
    one-time migration in two phases: a JMT v1 → v2 rebuild
    (`[MIGRATIONS] Blockchain database is at v6`, then `v6: Starting JMT v1 → v2 rebuild`, ending at
    `JMT rebuild complete`), then a compaction that copies the live data into a new `data.mdb`
    (`Compacting LMDB env`, `[MIGRATIONS] Pre-compaction data.mdb size`). On a mainnet-sized
    database the rebuild took about one to one and a half hours and the compaction about 80
    minutes more, shrinking the database from 161 GB to about 55 GB. The node opens gRPC only after
    both phases, so the dashboard shows Tari as loading with no progress for the whole time; follow
    the phases with `docker logs tari`. The node config keeps 2 GiB of LMDB map headroom so that dropping the
    old tables at the end of the rebuild does not fail with `MDB_MAP_FULL`
    ([#2593](https://github.com/p2pool-starter-stack/pithead/issues/2593)). The compacted copy sits
    beside the old database, so both are on the data volume at once. Before it starts or
    recreates any container, `./pithead upgrade` requires free space there of the current
    `data.mdb`'s size plus 5 GiB, and otherwise refuses, naming the volume, the size needed and the
    size free ([#2636](https://github.com/p2pool-starter-stack/pithead/issues/2636)). On the
    appliance, `pithead os-update` and the dashboard's OS-update verify and install steps refuse a
    bundle that declares a data migration against the same bound, before anything is installed
    ([#2645](https://github.com/p2pool-starter-stack/pithead/issues/2645)). The bound is
    conservative: the copy is smaller than the original. Do not
    stop, restart or `apply` the stack until the node reports progress again: the container is
    killed one minute after a stop, and upstream says not to interrupt the migration. The payout
    wallet (`tari.view_key`) migrates its database on its first start too. Tari 5.3.1 cannot open
    either database afterwards, so returning to an older Pithead release does not return Tari to
    a working state. Take a backup first (`./pithead backup --with-chains`).
  - **A node that followed the dead 5.3.1 branch past 350,000 is rewound on its own
    ([#2618](https://github.com/p2pool-starter-stack/pithead/issues/2618)).** Such a node bans
    every canonical peer for `Invalid Proof of work` after the migration and never syncs. The Tari
    entrypoint waits while the node's gRPC is closed or answers `UNAVAILABLE` (it does for the
    whole database migration), then compares the node's block header at 350,000 with the canonical
    hash. On a mismatch it rewinds the chain to 349,900, deletes the peer database (the bans) and starts
    the node again. A node below 350,000 or on the canonical chain is left as it is. Each step is
    logged in `docker logs tari` with the prefix `[pithead fork-check]`.
  - **Remote Tari (`tari.mode: remote`): upgrade the serving node to 6.0.1-pre.0 first.** P2Pool
    4.18.1 cannot merge-mine against a node older than 6.0.0, and a 6.0.0 node stops at 350,008.
  - The payout-confirmation scan counts Tari 6.0.0's new `*_CONFIRMED_LOCKED` transaction statuses
    (a mined output that has not matured yet), so a payout is still recorded when it is mined.

### Beta in 2.0.0

Beta means the feature is optional and off unless you turn it on, and a defect seen only with it
enabled may ship as a known issue. These are beta in 2.0.0; the label lives in the docs, this
changelog and the wizard text only, and dashboard badges come in 2.0.1.

- **Tari merge-mining:** off by default in the setup wizards; an upgrade keeps the bundled node.
- **XvB raffle:** off for new installs.
- **Payout confirmation:** the Monero and Tari view keys (`monero.view_key`, `tari.view_key`).
- **Remote rig control:** an appliance rig listens for control at every boot, pinned to the
  coordinator and gated by its token. Dashboard writes to a rig need adoption first.

### Known issues in 2.0.0

- On an appliance rig, a pool changed from Worker Inspect reverts at the next reboot: the rig's
  `rig.json` owns the pool. Change it in the rig's `rig.json` instead
  ([rigforge#583](https://github.com/p2pool-starter-stack/rigforge/issues/583)). The other
  Worker Inspect edits (`DONATION`, `autotune`, `watchdog`, `watchdog_interval_min`,
  `max_temp_c`) survive a reboot.
- On a no-login appliance, Tor auto-heal does nothing unless `dashboard.control.enabled` is set
  (#3166).
- On a DIY host whose GRUB configuration has malformed quoting, later `update-grub` runs can
  fail (#3305). Run setup with `--skip-optimize`, or remove
  `/etc/default/grub.d/zz-pithead-hugepages.cfg`.
- The order of the DIY firewall rules against Docker at reboot is untested (#2677).
- Automatic Tor recovery is a named soak risk: it restarts Tor on its own, and its long-run
  behaviour has had no soak time yet.

### Added

- Read-only `config_version` in `config.json`, hidden from Configuration. Only newer configs warn;
  restoring a backup from a newer release requires updating first ([#3109](https://github.com/p2pool-starter-stack/pithead/issues/3109)).

- **Stratum password is opt-in, and its connection details are shown wherever the pool URL is.**
  Both wizards ask `Enable stratum password?` and default to no. The setup hand-off card, the
  **Connect a miner** block (signed in, or on a dashboard with no login) and the CLI show the LAN
  pool URL and the password, or that none is set ([#3092](https://github.com/p2pool-starter-stack/pithead/issues/3092)).

- **The XMR Network card now says whether monerod is at the tip with peers.** It shows the outgoing and
  incoming peer counts and the age of the last height change, and goes red with the numbers after 10
  minutes with no outgoing peers or 30 minutes with no new height. `./pithead doctor` and `status`
  name the same condition, the monerod container reports `unhealthy` after 10 minutes with no outgoing
  peers, and each condition sends one alert through the `node_down` toggle. Nothing is restarted for
  you ([#2499](https://github.com/p2pool-starter-stack/pithead/issues/2499)).

- **A saturated Tor circuit history is reported, and `tor-recover` can reset it while Monero stays
  synchronized ([#3052](https://github.com/p2pool-starter-stack/pithead/issues/3052)).** Tor can
  finish bootstrapping with its circuit-build-time history full and still fail every clearnet
  request; a NEWNYM refresh does not clear it. With `tor.auto_heal` on, the dashboard reads Tor's
  circuit-history state on every heal round, logs a saturated history and sends one alert per
  outage naming `./pithead tor-recover`, retrying until a channel delivers it. `./pithead doctor`
  reports the same condition as a FAIL,
  which the Tor section of Service Diagnostics shows after a health check. `tor-recover check` and
  `apply` now also accept two failed heal rounds from the same outage at least 15 minutes apart,
  with both clearnet probes still failing through Tor, so a synchronized Monero node no longer
  blocks the reset. When the history stays saturated through the heal rounds, `tor.auto_heal` runs
  the same gated `tor-recover apply` itself ([#3118](https://github.com/p2pool-starter-stack/pithead/issues/3118)),
  keeping its cooldown, evidence and onion-identity checks. Its refreshes and recovery go through the
  host control runner, so the heal needs `dashboard.control.enabled`, which the appliance turns on
  only when a dashboard login is set. Without `tor.auto_heal` the reset stays an operator command.

- **The dashboard onion's client key without a shell.** With Tor client authorization on — the
  default, and mandatory whenever the config editor is on — a published `.onion` does not answer a
  browser that has no client key, and the key was printed by exactly one thing: `pithead
  onion-client-key`, on a host shell. An appliance has none, so turning the onion on there produced
  an address that was published, shown in the dashboard header, and impossible to open, under a
  note naming a command the reader could not run
  ([#1882](https://github.com/p2pool-starter-stack/pithead/issues/1882)). The header's
  client-authorization note now carries a **Show client key** button wherever the config editor is
  on. The host answers once — both Tor client forms — and wipes its own copy on the same timer the
  backup kit uses; every reveal is recorded in the config-change audit log. The key is still not in
  the dashboard container's environment
  ([#1880](https://github.com/p2pool-starter-stack/pithead/issues/1880) stands): the container
  asks, the host decides, and the answer crosses once through the read-only results spool.

- **Per-worker authentication reaches the dashboard's read probes**
  ([#2349](https://github.com/p2pool-starter-stack/pithead/issues/2349),
  [#1950](https://github.com/p2pool-starter-stack/pithead/issues/1950),
  [#2415](https://github.com/p2pool-starter-stack/pithead/pull/2415)). An explicit
  `workers.list[].api_token` supplies a read-only probe credential bound to that worker's host and
  API port. RigForge's write-capable `workers.list[].token` stays on the host; the dashboard receives
  only its separately derived read bearer. Missing or stale credentials fail closed, and the
  editor's config copy keeps both fields masked.

- **Pithead OS, the appliance.** Verify `pithead-os-v2.0.0.img.xz`, write its decompressed image
  to a USB stick, and boot the machine from it: it installs itself and serves a one-page setup
  wizard to your browser. The page asks
  what the machine is — a full coordinator, a coordinator that also mines with its own CPU, or a
  mining rig ([#797](https://github.com/p2pool-starter-stack/pithead/issues/797)) — which disk
  to use, and the same questions the DIY installer asks. A machine without a monitor can be set up
  from a file dropped on the stick ([#924](https://github.com/p2pool-starter-stack/pithead/issues/924)), and settings can be changed later the same way; a
  stick rewrite changes only the settings it names ([#910](https://github.com/p2pool-starter-stack/pithead/issues/910), [#965](https://github.com/p2pool-starter-stack/pithead/issues/965)).
- **Updates that fall back on their own.** The appliance keeps two copies of the system and writes
  an update to the idle one. It reboots into the new version, checks that the stack came up, and
  returns to the previous copy by itself when it did not. Updates are signed with a release key
  the machine verifies before installing; a release build refuses to run without an explicit key.
  An update is checked for, downloaded and installed from the dashboard's OS-update control
  ([#976](https://github.com/p2pool-starter-stack/pithead/issues/976)), or applied from a downloaded bundle with `pithead os-update`; the chain services start only
  after the new slot has committed, so a forward-only database migration never runs on a slot that
  might be rolled back.
- **Backups and restores.** `pithead backup` exports an encrypted archive ([#908](https://github.com/p2pool-starter-stack/pithead/issues/908)), and the setup
  wizard can restore one on a fresh machine ([#909](https://github.com/p2pool-starter-stack/pithead/issues/909)). A restored machine keeps its own identity:
  the machine-id and SSH host keys live on the data partition ([#894](https://github.com/p2pool-starter-stack/pithead/issues/894), [#895](https://github.com/p2pool-starter-stack/pithead/issues/895)), and the
  journal follows the machine rather than the boot ([#1659](https://github.com/p2pool-starter-stack/pithead/issues/1659)).
- **Two resets instead of an uninstall.** A config reset clears the settings and reopens the setup
  wizard, keeping the synced chain, the wallet and the Tor keys; a factory reset wipes the data
  partition. A data partition damaged by a power cut is repaired rather than erased ([#1062](https://github.com/p2pool-starter-stack/pithead/issues/1062)),
  and a container store left inconsistent by an interrupted write is rebuilt on the next boot
  ([#1029](https://github.com/p2pool-starter-stack/pithead/issues/1029)).
- **Host tuning baked into the image.** Hugepages are reserved at boot in proportion to the fitted
  RAM ([#977](https://github.com/p2pool-starter-stack/pithead/issues/977)) up to a declared ceiling that, on a single-socket machine, neither the host nor the miner unit
  can grow past ([#1103](https://github.com/p2pool-starter-stack/pithead/issues/1103), [#1724](https://github.com/p2pool-starter-stack/pithead/issues/1724)); the CPU governor is set to performance; a hardware watchdog resets a
  box whose kernel or init has hung, with nobody present. The Tor-only egress firewall is enforced under the
  appliance's own container engine, and IPv6 fails closed. The mining-rig role ships RigForge
  1.18.0 code at commit
  `b2d4c3d9ca1da74d0e6d5ccce772d401acc8be03`, before its release tag
  ([#1826](https://github.com/p2pool-starter-stack/pithead/issues/1826),
  [#3029](https://github.com/p2pool-starter-stack/pithead/issues/3029),
  [#3116](https://github.com/p2pool-starter-stack/pithead/issues/3116)).
- **Service Diagnostics in the dashboard ([#913](https://github.com/p2pool-starter-stack/pithead/issues/913), [#943](https://github.com/p2pool-starter-stack/pithead/issues/943)):** the host doctor's detail and a
  bounded, redacted tail of each service's log, without a shell.
- **The dashboard says where a rig's running configuration came from ([#1345](https://github.com/p2pool-starter-stack/pithead/issues/1345)),** persists the
  revision each rig serves ([#1551](https://github.com/p2pool-starter-stack/pithead/issues/1551)), detects a rig running something other than what was
  applied ([#1367](https://github.com/p2pool-starter-stack/pithead/issues/1367)), and records a rig configuration change nothing else had recorded
  ([#1558](https://github.com/p2pool-starter-stack/pithead/issues/1558)). Worker Inspect is prefilled from the rig's own configuration ([#1235](https://github.com/p2pool-starter-stack/pithead/issues/1235)), and each
  node card says whether that node runs locally or remotely ([#1040](https://github.com/p2pool-starter-stack/pithead/issues/1040)). The XvB decision table is
  rebuilt as per-tier blocks ([#1316](https://github.com/p2pool-starter-stack/pithead/issues/1316)).
- **The boot menu says what each entry boots, and offers "Set up again" ([#1318](https://github.com/p2pool-starter-stack/pithead/issues/1318), [#1838](https://github.com/p2pool-starter-stack/pithead/issues/1838)).**
  A set-up-again boot opens the setup page beside the saved role; the page opens by naming what the
  machine already is, with its rig data kept and offered back.
- **An appliance rig mints its own control token and shows it once ([#1836](https://github.com/p2pool-starter-stack/pithead/issues/1836)),** beside the
  address to adopt it at; it serves the sister feed and pins control to its coordinator.
- **`pithead doctor --json` and `pithead support-bundle`:** a machine-readable doctor report, and a
  redacted bundle for a support request that masks wallet and onion addresses as well as
  credentials ([#1585](https://github.com/p2pool-starter-stack/pithead/issues/1585)).

### Changed

- **Enabling or re-pointing Tari on a mining box keeps Monero mining while Tari syncs.** The
  preview row says so. The sync hold then applies to Monero only, so the miner and workers carry
  on; merge-mining starts when Tari has synced. The first-install hold on both chains is
  unchanged ([#3094](https://github.com/p2pool-starter-stack/pithead/issues/3094)).
- **New installs start from safer defaults in both wizards.** Tari is on when the disk fits both
  chains and off when it does not, the XvB raffle is off and not asked about, a dashboard login is
  generated and shown once unless you choose no login, and the first sync runs over Tor. The faster sync is an opt-in that
  covers each chain run locally and warns that it exposes your IP. Upgrades keep their config
  ([#3099](https://github.com/p2pool-starter-stack/pithead/issues/3099)).
- **`setup`, `up` and `apply` always print the pool URL and the stratum password state.** The
  password reads `none set` when there is none. An `apply` that only toggles `local_miner`
  converges the local miner instead of reporting no changes ([#3090](https://github.com/p2pool-starter-stack/pithead/issues/3090)).
- **The command line confirms a payout address change by its last 8 characters**, as the
  dashboard already did; it used to ask for the first 8 ([#3097](https://github.com/p2pool-starter-stack/pithead/issues/3097)).
- **`apply` and the dashboard refuse a config with a duplicate JSON key or a `PASTE_` or `YOUR_`
  placeholder value.** The refusal names the key and never prints the value ([#3098](https://github.com/p2pool-starter-stack/pithead/issues/3098)).
- **Appliance documentation corrections** for identity and update recovery ([#3100](https://github.com/p2pool-starter-stack/pithead/issues/3100)).
- **Payout confirmation keeps one view-only wallet per payout address and view key.** Changing the
  address or key opens a separate wallet instead of reusing the old one, reverting reopens the
  earlier wallet, and an upgrade adopts the existing wallet without recreating it. A new automatic
  Monero wallet starts 100 blocks behind the local node's tip. `apply` refuses a view key that does
  not belong to the configured address, for Monero and Tari, so a key from the wrong wallet fails at
  once instead of scanning forever ([#3096](https://github.com/p2pool-starter-stack/pithead/issues/3096)).
- **Tari payout confirmation needs only the view key.** `apply` derives the public spend key from
  the dual-key `tari.wallet_address`; `tari.spend_public_key` is optional and, with `tari.view_key`
  set, must match the address. A single-key Tari address is refused while `tari.view_key` is set;
  mining to it still works ([#2732](https://github.com/p2pool-starter-stack/pithead/issues/2732)).
- **The docs show where each view key lives in the Monero GUI wallet and Tari Universe**, and
  `apply`'s view-key messages point there ([#3112](https://github.com/p2pool-starter-stack/pithead/issues/3112)).
- **The Configuration view works the same, minus the Telegram round-trip.** A disruptive change
  still asks you to type `APPLY`. A payout change also asks for the last characters of the new
  address, after the host validates its checksum and network. Future rewards go to the new
  address. The action button reads
  "Confirm & apply" in every case — there is no longer an "Approve & apply" variant. A sensitive
  commit no longer depends on Telegram being set up at all: on a stack that never configured the
  bot, these changes used to fail with an approval-unavailable error and now apply normally.
- **Sensitive commits audit without an approver.** `commit-approved` and the audit log's `approver`
  field had exactly one writer, the Telegram verifier, so sensitive commits now record as `commit`
  or `commit-confirmed` against the signed-in dashboard user. Existing log rows are unchanged.

- **Remote nodes on a dual-stack LAN must be entered by their private IPv4 address**
  ([#2351](https://github.com/p2pool-starter-stack/pithead/issues/2351)). With the default Tor
  egress firewall, the setup wizard refuses a dual-stack hostname and names the private-address
  remedy.

- **The worker list keeps RigForge status chips short**
  ([#3031](https://github.com/p2pool-starter-stack/pithead/issues/3031)). Power and temperature
  stay in the list alongside warnings; version, mainboard, HugePages, a healthy governor, tune
  target and autotune details move to Worker Inspect, which keeps every existing row.

- **Every mutating `pithead` verb runs behind one mutation lock ([#1342](https://github.com/p2pool-starter-stack/pithead/issues/1342), [#1482](https://github.com/p2pool-starter-stack/pithead/issues/1482)).** Setup,
  apply, upgrade, the resets, rotate-secrets and the OS-update verbs serialise; a second invocation
  that arrives while one holds the lock is refused and told why, instead of two writers racing on
  the same files.
- **The Tari disk budget is 200 GiB ([#1011](https://github.com/p2pool-starter-stack/pithead/issues/1011)),** which raises the free space setup and
  `doctor` ask for.
- **The appliance builds docker-compose and cosign from source in its rootfs** instead of
  downloading release binaries.
- **A failed setup keeps the machine's existing configuration ([#1059](https://github.com/p2pool-starter-stack/pithead/issues/1059))** rather than discarding
  it, and the CLI degrades instead of aborting when the optional dashboard auth key is absent
  ([#1246](https://github.com/p2pool-starter-stack/pithead/issues/1246)).
- **The setup wizard opens on Pithead + RigForge, and the miner select is the switch ([#1830](https://github.com/p2pool-starter-stack/pithead/issues/1830)).**
- **The dashboard's Configuration view never shows `ssh.*` and never changes it ([#1850](https://github.com/p2pool-starter-stack/pithead/issues/1850)),** and
  its Advanced pane says what it does with a key.

### Removed

- **Release images no longer accept the `ssh.*` configuration options.** SSH is now a debug-build
  property; a carried 1.x `ssh.enabled: true` setting is ignored and reported rather than blocking
  an update.

- **Telegram is a read-only notification channel.** The bot still answers `/status`, `/info`,
  `/hashrate`, `/workers`, `/sync`, `/system`, `/pool`, `/xvb`, `/earnings`, `/luck` and `/help`,
  and still sends every event alert and the daily summary. Its two write surfaces are gone
  ([#2076](https://github.com/p2pool-starter-stack/pithead/issues/2076)):
  - The `/restart` and `/apply` control commands ([#338](https://github.com/p2pool-starter-stack/pithead/issues/338)),
    with the `telegram.control` config block (`enabled`, `allowed_ids`, `confirm_timeout`).
  - The Telegram approval tap on a sensitive Configuration-view commit ([#911](https://github.com/p2pool-starter-stack/pithead/issues/911)).
    Changing a payout wallet, a node endpoint or any other sensitive setting no longer sends a
    prompt to Telegram and no longer waits for anyone to tap a button.

  `apply` drops `telegram.control` from an existing `config.json` on the next run, so no manual
  edit is needed. If you had the control commands enabled, it says so once as it removes the key.

- **The two 1.x configuration aliases ([#1832](https://github.com/p2pool-starter-stack/pithead/issues/1832)).** `dashboard.workers[]` is `workers.list[]`, and
  `xmrig_proxy.{enabled,url,donor_id}` is `xvb.*`. A 1.x configuration is migrated in place once, the
  first time 2.0.0 reads it; after that the old names are unknown to the product. A configuration that
  sets a non-default old value and its replacement to different values is refused.

### Fixed

- **Configuration drafts survive a view change.** Edits in the configuration editor are kept when
  you move to another dashboard view and back, and after an apply that fails ([#3273](https://github.com/p2pool-starter-stack/pithead/pull/3273)).
- **The setup wizard's plain-HTTP port redirects to HTTPS.** A plain `http://` LAN URL is
  redirected to an HTTPS host address: the host you typed, or the first host address or
  `pithead.local`. Caddy keeps a recognised typed host after provisioning ([#3236](https://github.com/p2pool-starter-stack/pithead/pull/3236)).
- **The boot menu names the boot disk.** Each GRUB entry says whether it boots the USB stick or the
  internal disk, and a debug build's label appears only in the slot title ([#3230](https://github.com/p2pool-starter-stack/pithead/pull/3230),
  [#3238](https://github.com/p2pool-starter-stack/pithead/pull/3238)).
- **The boot health wait shows progress.** The appliance reports what it is waiting for on the
  console during the health gate ([#3203](https://github.com/p2pool-starter-stack/pithead/pull/3203)).
- **Failed-login counts survive Caddy log rotation.** The security view keeps its recent
  failed-login history when the access log rotates ([#3270](https://github.com/p2pool-starter-stack/pithead/pull/3270)).
- **`restore` works after `config-reset` on the Docker-Compose install** ([#3282](https://github.com/p2pool-starter-stack/pithead/pull/3282)).
- **`pithead doctor` shows no tip age for an unset Monero tip timestamp**, instead of an age
  measured from 1970 ([#3280](https://github.com/p2pool-starter-stack/pithead/pull/3280)).
- **Expected Tor recovery refusals are not reported as aborts.** A healthy Tor that refuses
  `tor-recover` no longer leaves abort diagnostics ([#3266](https://github.com/p2pool-starter-stack/pithead/pull/3266)).
- **The backup kit survives a failed archive download.** A download that fails (the Chrome case
  included) keeps the kit available for a retry; the backup guide has the clean-profile workaround
  ([#3272](https://github.com/p2pool-starter-stack/pithead/pull/3272)).
- **P2Pool pool statistics are hidden while the sidechain syncs**, instead of showing bootstrap
  values ([#3250](https://github.com/p2pool-starter-stack/pithead/pull/3250)).
- **Update errors can be dismissed, and the dashboard explains how to reconnect** after the
  certificate changes ([#3243](https://github.com/p2pool-starter-stack/pithead/pull/3243)).
- **The what-if calculator rejects a malformed hashrate** and parses grouped numbers ([#3268](https://github.com/p2pool-starter-stack/pithead/pull/3268)).
- **Worker Inspect edits survive an appliance rig's reboot.** The rig role's boot-time rebuild of
  RigForge's config no longer drops `DONATION`, `autotune`, `watchdog`, `watchdog_interval_min` and
  `max_temp_c`; a pool change still reverts (see Known issues)
  ([#3204](https://github.com/p2pool-starter-stack/pithead/issues/3204)).
- **Worker Inspect says a `DONATION` below the miner's built-in minimum has no effect**
  ([#3206](https://github.com/p2pool-starter-stack/pithead/issues/3206)).
- **XvB keeps its full P2Pool dwell when the raffle is disabled** ([#3226](https://github.com/p2pool-starter-stack/pithead/pull/3226)).
- **Workers and rigs are probed only while online**, or while their feed last answered
  ([#3211](https://github.com/p2pool-starter-stack/pithead/pull/3211)); workers are kept across a
  transient proxy fetch failure ([#3201](https://github.com/p2pool-starter-stack/pithead/pull/3201)).
- **The setup wizard rejects duplicate JSON keys and template placeholders** ([#3200](https://github.com/p2pool-starter-stack/pithead/pull/3200)).
- **`pithead doctor` accounts for stratum protection and Tor control** in its exposure checks
  ([#3202](https://github.com/p2pool-starter-stack/pithead/pull/3202)).
- **A legacy payout wallet is verified before it is adopted** ([#3177](https://github.com/p2pool-starter-stack/pithead/pull/3177)).
- **A crashed LAN-published node restarts** while the LAN-guard source rule is live ([#3295](https://github.com/p2pool-starter-stack/pithead/pull/3295)).
- **`cosign` and `docker-compose` are built on Go 1.26.9**, which clears two Go standard-library
  CVEs in the image scan ([#3294](https://github.com/p2pool-starter-stack/pithead/pull/3294)).
- **Persistent HugePages setup keeps cloud GRUB arguments.** Setup writes its own
  `/etc/default/grub.d/zz-pithead-hugepages.cfg`, keeps existing boot arguments including cloud
  console settings, verifies the generated kernel entries after `update-grub`, repairs earlier
  Pithead reservations on re-run, and asks for no second reboot when the running kernel already has
  the flags ([#3281](https://github.com/p2pool-starter-stack/pithead/pull/3281)).
- **A Tari outage no longer rejects workers at once.** With `tari_required`, workers are rejected
  only after a sustained Tari RPC outage; migrating, starting and syncing only alert. Once the
  Monero node has answered, an outage, local or remote, always rejects ([#3091](https://github.com/p2pool-starter-stack/pithead/issues/3091)).
- **Tor recovers from a saturated circuit-build history.** An early alert, and under
  `tor.auto_heal` a self-heal, reset Tor through the gated `./pithead tor-recover`; the doctor and
  the Monero card's advice name it ([#3118](https://github.com/p2pool-starter-stack/pithead/issues/3118)).
- **An IPv6 address that arrives after boot no longer leaves a permanent doctor FAIL (#2463).** A new
  timer checks the machine's addresses every five minutes and, when they changed since the last
  render, re-renders the dashboard certificate and Caddyfile and restarts Caddy if either changed.
  The certificate check also compared an IPv6 address's two spellings (openssl's expanded form and
  `hostname -I`'s compressed one) as different strings, so any IPv6 address was reported uncovered and
  re-minted the certificate on every render; both sides are now canonicalised.

- **Clearnet initial sync works behind the default egress firewall
  ([#2649](https://github.com/p2pool-starter-stack/pithead/issues/2649),
  [#2678](https://github.com/p2pool-starter-stack/pithead/issues/2678)).** An opted-in Monero or
  Tari node gets its own temporary direct-dial exception while other containers stay restricted.
  On sync, the host closes and verifies that exception before the node restarts on Tor; the
  dashboard keeps the transition warning until the host verifies the live Tor daemon and rules.
  A completed sync stays on Tor across apply and reboot.
- **monerod flushes every chain-database commit to disk
  ([#2471](https://github.com/p2pool-starter-stack/pithead/issues/2471)).** monerod's default
  database mode, `fast:async`, opens LMDB with `MDB_NOSYNC` while the node is syncing and only
  syncs its commits once it reaches the chain tip, so a power cut during the initial sync or a
  catch-up could lose commits the node had already made. The bundled node now runs with
  `db-sync-mode=safe`, which syncs every commit, so a power cut can no longer take the chain back
  below a height it had already committed. At the tip nothing changes. While syncing, each commit
  now waits for two disk flushes, and the bytes written are the same. Counted from the monerod
  0.18.5.1 source, a full pruned mainnet sync to height 3.77 million makes at most about 295,000
  commits when every download batch is full, and at most about 7.56 million if every batch holds
  one block. The added time is the number of flushes times the disk's flush time, which was not
  measured: for each millisecond a flush takes, about 10 minutes with full batches and at most
  4.2 hours.

- **Tari payout confirmation now finds payouts
  ([#2731](https://github.com/p2pool-starter-stack/pithead/issues/2731)).** The view-only wallet's
  `tari.payout_scan_birthday` counts days since 2022-01-01, Tari's unit (Tari Universe's
  `wallet_birthday` works as-is). `auto` was computed from 1970, a day in 2078, so the wallet started
  at the chain tip and missed every earlier payout; a birthday later than today is now refused. The
  wallet also scans through the local Tari node's wallet HTTP service on the internal network only;
  it had no working base-node setting and fell back to Tari's public node over clearnet. The wallet
  also never started. Its volume was mounted where the image's uid-1000 user could not write, so it
  crash-looped creating its config directory. It now uses a new volume, `tari_wallet_db`, on the
  image's own `/var/tari/wallet`, so every install creates the wallet fresh and scans from the
  birthday. The old `tari_wallet_data` volume never held a wallet; `uninstall` removes it.

- **A slow first Tor bootstrap no longer fails provisioning
  ([#2648](https://github.com/p2pool-starter-stack/pithead/issues/2648)).** monerod and tari wait
  for Tor's healthcheck, and the healthcheck marked Tor unhealthy about 3.5 minutes after it
  started. A cold bootstrap on a fresh Tor data directory has taken 5 minutes. When it ran that
  long, `docker compose up` stopped with `dependency tor failed to start` and never started the
  nodes. On the appliance, the setup wizard reopened with the configuration marked as failed. Tor
  now has 10 minutes to bootstrap before failed checks count against it. A Tor that bootstraps
  sooner is marked healthy at its next 30-second check, as before. A Tor that never bootstraps
  now fails `up` after about 12.5 minutes instead of 3.5.

- **Inbound peers reach the Monero onion, and the P2Pool onion on main and nano
  ([#2936](https://github.com/p2pool-starter-stack/pithead/issues/2936)).** The bundled monerod
  bound its anonymous P2P listener to its own container's loopback, which the Tor container cannot
  reach, so the Monero onion answered no peer. It now listens on the stack's container bridge at
  `:18084`; the port is still not published on the host. The P2Pool onion always forwarded to
  `37888`, the mini sidechain's port, so on main or nano it led nowhere. It now forwards the
  selected sidechain's P2P port: `37889` main, `37888` mini, `37890` nano. RPC access and remote
  nodes are unchanged.

- **The Tor self-heal no longer leaves Tor stopped after a restart
  ([#3032](https://github.com/p2pool-starter-stack/pithead/issues/3032)).** With `tor.auto_heal`
  on, the heal's stop request gave up after 60 seconds, just before a wedged Tor finished stopping.
  The start that followed was answered "already running" by the Tor that was still going
  down, so Tor stayed stopped and monerod sat with no outgoing peers until someone started it. The
  stop now waits up to two minutes, an unconfirmed stop gets up to 30 seconds to settle before the
  start, and an unconfirmed start is tried up to three times, five seconds apart.

- **`./pithead tor-recover check` accepts a peerless Monero node that still reads synchronized
  ([#3033](https://github.com/p2pool-starter-stack/pithead/issues/3033)).** The check, which
  `tor-recover apply` repeats before it resets a saturated Tor circuit history, looks for a local
  Monero node stalled with no peers. It required `synchronized: false`, but monerod keeps its last
  value after losing every peer, so a node held at one height with 0 outgoing peers for three
  minutes was refused. The check now takes 0 outgoing peers at an unchanged height as the stall,
  whatever `synchronized` says. Every other guard is unchanged.

- **The Monero payout wallet stays healthy while a restarted wallet catches up
  ([#2756](https://github.com/p2pool-starter-stack/pithead/issues/2756)).** The scan grace applied
  only to a newly created wallet. A reopened wallet that had to catch up, for example after the
  Monero node came back from remote mode, blocked its RPC for the whole catch-up and `pithead status`
  reported it unhealthy. The wallet now marks a scan on every start, bounded by the same 24-hour
  grace.
- **The Monero payout wallet's scan grace ends at monerod's tip, and a crash loop no longer renews
  it ([#2720](https://github.com/p2pool-starter-stack/pithead/issues/2720)).** The RPC answers
  between refresh passes, so the first answer no longer retires the grace mid-scan; the healthcheck
  clears it once the wallet height reaches monerod's block count. A restart keeps an existing
  marker's age, so a wallet that never catches up still turns unhealthy after 24 hours. Its ring
  database moved into the wallet volume, off the read-only root filesystem.
- **Worker Inspect can adopt a rig again
  ([#2641](https://github.com/p2pool-starter-stack/pithead/issues/2641)).** The former perimeter
  policy refused every change to `workers.list[]`, including the append the **Adopt this rig**
  form sends, so the form always failed at the preview. An appliance rig set up by the wizard had
  no way to be adopted short of a configuration stick. The host now lets an append through: every
  existing descriptor must come back unchanged, a new rig may not reuse an existing rig's name,
  its host must not resolve to loopback, link-local or the stack's own docker-bridge subnet, and
  the commit needs the typed `APPLY`. The preview names the rig and the
  address the dashboard will send its control token to, and the audit log records the commit as
  confirmed with `workers.list` as its key. Repointing or removing a rig the dashboard already
  controls is still refused.

- **An unreachable image registry is no longer reported as a bad signature
  ([#2735](https://github.com/p2pool-starter-stack/pithead/issues/2735)).** When cosign cannot
  reach the registry, for example `no route to host`, the start and upgrade paths still refuse to
  pull, and now say the image is unverified because of a network error. Before, they said the published image did not
  match the release key, which sent operators looking for a tampered image.

- **A restore at setup no longer carries the source machine's released miner onto new hardware
  ([#2626](https://github.com/p2pool-starter-stack/pithead/issues/2626)).** The backup's dashboard
  database records that the source machine's chains had synced and its miner was released. Restored
  onto a machine whose chains had not synced, the dashboard never held `p2pool`, which ran without
  its stratum port and stayed unhealthy, so the appliance boot never committed. The wizard and
  carried restore doors now leave a marker that makes the dashboard hold the miner until this
  machine's own chains are synced. `./pithead restore`, the same-box recovery command, is
  unaffected: its box's chains never desynced, so it keeps the backup's gate state as before.

- **A source checkout starts the whole stack after `uninstall` or on a new host
  ([#2654](https://github.com/p2pool-starter-stack/pithead/issues/2654)).** `setup`, `up`, `apply`
  and `upgrade` on a source checkout run Compose with `--pull never` so the local `:dev` images are
  built, not pulled. The digest-pinned Tari, Caddy and socket-proxy images have no build context, so
  once `uninstall` had removed them only `tor` started. `pithead` now pulls the missing images that
  have no build context before it starts the stack. An explicit `PITHEAD_PULL` still overrides this.

- **`pithead` no longer logs a false `pithead aborted unexpectedly (exit 2)`
  ([#3047](https://github.com/p2pool-starter-stack/pithead/issues/3047)).** Tidying the dashboard's
  control results printed that error whenever there was no backup archive to prune, for example at
  every appliance boot, while the command carried on and finished. What is pruned is unchanged.

- **A restore at setup that fails while writing its files no longer leaves the machine half
  restored ([#2689](https://github.com/p2pool-starter-stack/pithead/issues/2689)).** It used to
  replace `config.json` and `.env` first and could then fail on the Tor keys or the dashboard
  database, leaving the archive's configuration beside this machine's own keys. Every item is now
  staged beside its destination and swapped in only when all are ready; any failure puts back
  the previous configuration, Tor keys and database, and removes the chain files the restore
  added.

- **`pithead doctor` no longer reports HugePages OK for a pool too small to use
  ([#2610](https://github.com/p2pool-starter-stack/pithead/issues/2610)).** Any non-zero
  `HugePages_Total` read OK, so a box with 186 pages passed while P2Pool's RandomX dataset and caches
  need 1296. doctor now holds the pool to this machine's budget (3072 pages, or the appliance's
  reduced pool, never below 1296) and warns when it is short. The warning gives the shortfall and
  the memory P2Pool uses outside the pool instead. It stays a warning, never a failure, because the
  appliance's update commit gate takes doctor's exit code.

- **P2Pool no longer restart-loops with exit 137 when the HugePages reservation is short
  ([#2562](https://github.com/p2pool-starter-stack/pithead/issues/2562)).** Without enough free
  HugePages, P2Pool puts its 2592 MiB RandomX dataset and caches in ordinary memory. Its 1 GB
  container ceiling OOM-killed it while it filled the dataset, on every start. That happened on a
  host where `setup` skipped the persistent GRUB change and was then rebooted, and on a pool other
  processes had used up. The ceiling is now 4 GB, both in Compose and in the appliance's units.
  When the reservation holds the dataset, which is still the fast path, nothing changes.

- **Mining no longer starts on a Monero chain that has not synced
  ([#2472](https://github.com/p2pool-starter-stack/pithead/issues/2472)).** A local monerod that has
  just restarted and has no peers yet reports a target height of 0. The dashboard read that as
  "synced", released `p2pool` and `xmrig-proxy`, and saved the release, so every later dashboard
  restart kept the miner running. The sync gate now also waits for monerod's own `synchronized`
  flag, and it counts an empty or partial node reading as not synced.

- **An approved configuration apply is no longer failed by a container that is merely
  mid-restart ([#2218](https://github.com/p2pool-starter-stack/pithead/issues/2218)).** The
  dashboard stops and starts p2pool on its own for the sync gate and for node-down worker
  failover, so a `docker compose up` could reach that container between states. Compose aborts
  the whole `up` when one container is in an improper lifecycle state, which failed the apply
  outright — the configuration was written, the containers were not recreated, and the box was
  left needing a manual `pithead apply` nobody was there to run. Dashboard container start/stop
  requests now take the same advisory lock as CLI mutations, so either operation waits for the
  other to finish instead of sending overlapping lifecycle requests to the engine.

- **The setup wizard's restore accepts a genuine backup from a prior supported release.** A
  backup made by the v1.20.0 Compose bundle stores its files under whatever directory the
  operator ran it from, not this appliance's own working directory. The wizard's restore used to
  compare every archive member against its own directory only, so a real v1.20.0 archive was
  refused before it ever reached configuration validation
  ([#2181](https://github.com/p2pool-starter-stack/pithead/issues/2181)). It now finds the
  archive's own working directory from where `config.json` sits and accepts the same backup
  layout rooted there, still refusing anything that mixes roots or strays outside it.
- **The installer-carried restore lands on a `wipe=keep` target, and never forces a chain resync
  ([#2195](https://github.com/p2pool-starter-stack/pithead/issues/2195)).** A `wipe=keep`
  reinstall keeps the target's prior `config.json`, and firstboot used to skip the carried
  restore entirely whenever that file was already present — it now always attempts it, and a
  present `config.json` is simply what the restore replaces. Restoring `data/monero`,
  `data/tari` and `data/p2pool` also used to delete the target's own directory outright before
  writing the archive's; it now merges the archive's files in instead, so the target's already-
  synced chain data survives a restore that carries none of its own.

- **An editor-saved 1.x configuration upgrades without a false XvB conflict**
  ([#2690](https://github.com/p2pool-starter-stack/pithead/issues/2690),
  [#2699](https://github.com/p2pool-starter-stack/pithead/pull/2699)). Untouched `xmrig_proxy.*`
  reference defaults no longer conflict with customised `xvb.*` values in either CLI migration or
  wizard restore; `xvb.*` wins and the removed block is dropped. A non-default legacy value that
  differs from its replacement is still refused.

- **The boot health gate re-mints a TLS certificate that the machine's address outran
  ([#1265](https://github.com/p2pool-starter-stack/pithead/issues/1265)),** `apply` reaches that re-mint on an unchanged configuration, and a rollback names
  the check that held the gate instead of a generic message. A slot that fails its health gate
  reboots once instead of stalling ([#1065](https://github.com/p2pool-starter-stack/pithead/issues/1065)), and the post-commit release of the chain services
  retries a container caught mid-transition and alerts when it cannot start ([#1684](https://github.com/p2pool-starter-stack/pithead/issues/1684)).
- **A failed data-migration fallback restores the data-partition floor ([#1393](https://github.com/p2pool-starter-stack/pithead/issues/1393))** from the
  record the raise now leaves, instead of leaving it wrongly raised.
- **The setup wizard's plain-port redirect ([#1118](https://github.com/p2pool-starter-stack/pithead/issues/1118)) and a provisioned machine's port-80 redirect
  ([#1123](https://github.com/p2pool-starter-stack/pithead/issues/1123)) no longer trust the Host header;** the dashboard is kept off globally routable
  addresses ([#1021](https://github.com/p2pool-starter-stack/pithead/issues/1021)); boot asks for the dashboard's own site and tells it apart from the default
  virtual host ([#1140](https://github.com/p2pool-starter-stack/pithead/issues/1140)); a wizard retry keeps its TLS session ([#1063](https://github.com/p2pool-starter-stack/pithead/issues/1063)).
- **The installer's remote-node preflight tests for a live ZMQ publisher ([#1497](https://github.com/p2pool-starter-stack/pithead/issues/1497)),** not just an
  open port. A checksum-invalid Monero or Tari payout address is refused before anything launches.
- **Slow image loads on USB media are narrated ([#1028](https://github.com/p2pool-starter-stack/pithead/issues/1028))** with a rising elapsed count, so a
  working box no longer looks like a hung one, and setup states its stop reason on every console.
- **The xmrig-proxy healthcheck no longer raises a false alarm on an image that predates its
  healthcheck script ([#1098](https://github.com/p2pool-starter-stack/pithead/issues/1098)).**
- **doctor's remedial text names what the operator can actually reach on the surface they are on
  ([#1213](https://github.com/p2pool-starter-stack/pithead/issues/1213)),** and looks for the control units where `apply` writes them ([#1151](https://github.com/p2pool-starter-stack/pithead/issues/1151)). The
  stratum-exposure warning names the one remedy an appliance operator has and stops printing the
  host's public address ([#1772](https://github.com/p2pool-starter-stack/pithead/issues/1772)); the missing-data-dir warning is worded the same way
  ([#1776](https://github.com/p2pool-starter-stack/pithead/issues/1776)); and a failed configuration save in the dashboard labels the host's `apply` log as
  the machine's own log and names only the controls on that page ([#1769](https://github.com/p2pool-starter-stack/pithead/issues/1769)).
- **Dashboard:** the XvB Odds cell names what it is waiting for instead of showing a dash
  ([#1231](https://github.com/p2pool-starter-stack/pithead/issues/1231)); an audit row id no longer collides with another rig's ([#1566](https://github.com/p2pool-starter-stack/pithead/issues/1566)); a failing payout
  sync no longer skips the steps beneath it ([#1644](https://github.com/p2pool-starter-stack/pithead/issues/1644)); the poll counter advances through a
  failed poll ([#1637](https://github.com/p2pool-starter-stack/pithead/issues/1637)); Monero clients validate the shape of a response body ([#1592](https://github.com/p2pool-starter-stack/pithead/issues/1592)); a
  full history window no longer fails to settle who changed a configuration ([#1369](https://github.com/p2pool-starter-stack/pithead/issues/1369)), and a
  failed history read is no longer shown as another dashboard's change ([#1409](https://github.com/p2pool-starter-stack/pithead/issues/1409)).
- **A reinstall's pre-fill drops the login but keeps the switches that need it ([#1846](https://github.com/p2pool-starter-stack/pithead/issues/1846)),** and a
  rig running from the USB stick is no longer told the disk is being copied ([#1835](https://github.com/p2pool-starter-stack/pithead/issues/1835)).
- **The confirm countdown for settings applied from the stick stays bounded when a login prompt
  contends for the console ([#1823](https://github.com/p2pool-starter-stack/pithead/issues/1823));** the console read that could park forever now runs under a
  timeout, at the cost of a countdown up to twice its length on a contended console.
- **The persistent journal has one home ([#1791](https://github.com/p2pool-starter-stack/pithead/issues/1791)):** its bind onto `/var/log/journal` is ordered
  after the `/var` overlay, so `journalctl --list-boots` lists every boot instead of the ones that
  won a race. On a mining rig the bind stands down, and the rig's write-minimising reclaim no
  longer fails the boot when it meets a journal bind that is still mounted ([#1817](https://github.com/p2pool-starter-stack/pithead/issues/1817)).

### Security

- **The dashboard password hash no longer reaches the appliance journal** ([#3131](https://github.com/p2pool-starter-stack/pithead/issues/3131)).
- **The Tor-only egress firewall now survives a DIY host reboot.** A reboot emptied `DOCKER-USER`
  while the containers restarted on their own, so a DIY host mined without the fail-closed rules
  until someone ran `./pithead up`. `up`, `apply` and `upgrade` now install
  `pithead-egress.service`, ordered before `docker.service`, which restores the rules before any
  container starts; `doctor` warns when it is not enabled
  ([#2460](https://github.com/p2pool-starter-stack/pithead/issues/2460)).
- **The Tari node no longer runs its own Tor
  ([#2653](https://github.com/p2pool-starter-stack/pithead/issues/2653)).** The upstream
  `minotari_node` image is built with Tari's `libtor` feature, and `use_libtor` defaults to on.
  Under the `tor` transport the node therefore started an in-process Tor, gave it its control port
  and hidden service, and let it dial Tor relays straight from the tari container rather than
  through the stack's `tor` container. Tari's source shows the same default in the released 5.3.1
  pin. The egress firewall drops those dials. A tier-4 run found one still open after a fault test
  briefly removed and reinstalled the rules; the firewall's established-flow accept kept it
  ([#2672](https://github.com/p2pool-starter-stack/pithead/issues/2672)). With the firewall off,
  nothing stopped them. Tari now uses the `socks5` transport through the stack's Tor SOCKS port
  with `use_libtor = false`. Onion and `/ip4` peers are both dialled through Tor, and inbound peers
  reach the node through the stack Tor's Tari onion, which now has a listener behind it. A node
  upgraded from the `tor` transport keeps its old onion in `config/base_node_id.json` under the
  Tari data dir, next to the stack's one. Nothing serves the old onion any more. That is harmless:
  peers still reach the node through the stack's onion.

- **The LAN switches now enforce LAN sources**
  ([#2616](https://github.com/p2pool-starter-stack/pithead/issues/2616)).
  `monero.rpc_lan_access`, `monero.zmq_lan_access` and `tari.grpc_lan_access` accept connections
  only from loopback, private and CGNAT (`100.64.0.0/10`) addresses; before, their ports took any
  source that could route to the host. See
  [LAN-only sources](docs/configuration.md#lan-only-sources).

- **The LAN-only source rule now survives a DIY host reboot.** A reboot cleared the rule while
  Docker restarted the node containers still published on every interface, so `18081`, `18083`
  and `18142` took any source until `./pithead up`. `pithead-lan-guard.service`, ordered before
  `docker.service`, now restores the rule. The node containers that publish a LAN port run with
  restart policy `no`, and `pithead-lan-hold.service` starts them only after the guard succeeds, so
  a guard that fails at boot leaves them stopped instead of exposed. While the rule is missing, the
  nodes refuse to start with a LAN bind however they are started (`docker start`, a compose run
  outside pithead), and `./pithead restart` and the Tor auto-heal do not try. Docker no longer restarts a
  crashed `monerod` or `tari` on such a host; `./pithead doctor` and a `container_unhealthy` alert
  name the node and the reason, and `./pithead up` recovers. The first `up` after upgrading
  recreates those containers once. If either unit cannot be installed, the ports stay on `127.0.0.1`
  ([#2749](https://github.com/p2pool-starter-stack/pithead/issues/2749)).

- **The dashboard alerts when the Tor-only egress firewall is missing.** The dashboard took the
  firewall's state from `network.tor_egress_firewall`, so it reported "blocked by the egress
  firewall" over an open egress. `pithead-egress.timer` now runs `pithead egress-status` every two
  minutes and writes the host's live verdict for the dashboard. A missing firewall turns the egress
  badge and panel into a warning and sends one `clearnet_exposed` alert, with one more when the
  rules are back. A missing or stale verdict reads as unverified, not as green
  ([#2599](https://github.com/p2pool-starter-stack/pithead/issues/2599)).

- **Dashboard authentication is the configuration-editing perimeter**
  ([#1959](https://github.com/p2pool-starter-stack/pithead/issues/1959),
  [#2305](https://github.com/p2pool-starter-stack/pithead/pull/2305),
  [#2428](https://github.com/p2pool-starter-stack/pithead/pull/2428)). Low-risk operational
  settings commit directly; other reference settings use the typed confirmation. A signed-in
  operator can change payout addresses, view keys, node and stratum credentials, XvB destinations,
  notification credentials and URLs, onion exposure, LAN binds, the control-channel switch and the
  Tor egress firewall. The dashboard password and the wallet-change and clearnet-exposure alarm
  toggles also confirm behind typed `APPLY` and the confirmation envelope. The preview names the
  password's session-lockout cost (on the appliance it also changes the console `root` login),
  silenced alarms and changed exposure. `ssh.*` is absent from release images.
- **Confirmation prevents mistakes; it is not a second identity.** The Telegram tap is gone.
  A compromised dashboard process can supply its own actor, `APPLY`, confirmation envelope and
  payout suffix. The audit records the signed-in actor but cannot prove that actor approved a
  request created after compromise. Host-side schema and payout-address validation, authenticated
  node reachability checks, credential-to-destination binding and data-root confinement still
  apply. A payout change cannot share a commit with `dashboard.data_dir`, preserving the
  wallet-change alarm's baseline through the supported commit path. The dashboard's own database
  and notifiers are not independent protection against a full process compromise.
- **Existing rig descriptors remain host-only.** The dashboard may append a new rig behind typed
  `APPLY` and host-side target validation, but cannot edit, repoint, reorder or remove an adopted
  rig, including its credentials. Those changes use `./pithead apply` on a DIY host or a
  configuration stick on an appliance. Host-side bearer requests are pinned to the numeric address
  that passed validation. See [`SECURITY.md`](SECURITY.md).
- **Dashboard passwords stay out of process arguments**
  ([#2799](https://github.com/p2pool-starter-stack/pithead/issues/2799),
  [#2803](https://github.com/p2pool-starter-stack/pithead/pull/2803)). Setup, apply, dashboard
  password changes and restore feed the password to Caddy's hash command through Docker stdin,
  rather than `--plaintext` in a command line readable by another local user.

- **Secrets stay out of what the product prints.** A Monero address in log body text is redacted,
  not only on the launch line ([#1750](https://github.com/p2pool-starter-stack/pithead/issues/1750)); the p2pool entrypoint's audit line masks secret values
  and keeps flag names visible ([#1586](https://github.com/p2pool-starter-stack/pithead/issues/1586)); the pool credential is masked rather than stripped so
  a dashboard Apply cannot wipe it ([#1548](https://github.com/p2pool-starter-stack/pithead/issues/1548)); the pool password is no longer kept in the
  worker-change record ([#1543](https://github.com/p2pool-starter-stack/pithead/issues/1543)); an audit row's id is bounded and digested so an unauthenticated
  rig cannot grow it without limit ([#1561](https://github.com/p2pool-starter-stack/pithead/issues/1561)); adopting a rig from the dashboard passes a
  resolve-and-check gate against server-side request forgery.
- **A rig's own input cannot stop or grow the dashboard.** The out-of-band change audit's flood
  cap bounds how many device-chosen names hold a window at once, so a rig that varies its name
  cannot grow the dashboard's memory without limit ([#1695](https://github.com/p2pool-starter-stack/pithead/issues/1695)); during a flood a name with no live
  window is refused and one marker records the episode. A change id, reason or worker name that
  sqlite cannot encode is handled at the bind instead of ending the poll step ([#1696](https://github.com/p2pool-starter-stack/pithead/issues/1696)).
- **Shipped images carry current fixes.** openssl is patched past the digest-pinned base images
  (CVE-2026-14456, [#1438](https://github.com/p2pool-starter-stack/pithead/issues/1438)); x/crypto and grpc are raised so the appliance rootfs scan is clean
  ([#1649](https://github.com/p2pool-starter-stack/pithead/issues/1649)); a CVE in the appliance rootfs is fixed at its source ([#1153](https://github.com/p2pool-starter-stack/pithead/issues/1153)).

### Known issues

These ship in 2.0.0 and are fixed after it.

- **Tor auto-heal needs dashboard control.** Without `dashboard.control.enabled`, which includes every
  appliance set up with **No login**, `tor.auto_heal` only detects and logs Tor trouble and cannot
  refresh or recover Tor; `pithead doctor` says so. Turn dashboard control on, or restart Tor by hand with
  `./pithead restart tor` ([#3166](https://github.com/p2pool-starter-stack/pithead/issues/3166)).

Older releases (before 2.0.0) are archived in [docs/changelog-archive.md](docs/changelog-archive.md).
