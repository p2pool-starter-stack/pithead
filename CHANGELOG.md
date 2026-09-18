# Changelog

All notable changes to **Pithead** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pithead ships as **one product, one version** — the version lives in the top-level
[`VERSION`](VERSION) file and every released image is tagged with it. Releases are cut
per the process in [`docs/dev/releasing.md`](docs/dev/releasing.md).

## [Unreleased]

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

### Changed

- **The Configuration view works the same, minus the Telegram round-trip.** A disruptive change
  still asks you to type `APPLY`. (A payout change asked for the last characters of the new address
  as well; the perimeter fix below made payout addresses host-only again, so that prompt no longer
  appears.) The action button reads
  "Confirm & apply" in every case — there is no longer an "Approve & apply" variant. A sensitive
  commit no longer depends on Telegram being set up at all: on a stack that never configured the
  bot, these changes used to fail with an approval-unavailable error and now apply normally.
- **Sensitive commits audit without an approver.** `commit-approved` and the audit log's `approver`
  field had exactly one writer, the Telegram verifier, so sensitive commits now record as `commit`
  or `commit-confirmed` against the signed-in dashboard user. Existing log rows are unchanged.

### Security

- **The dashboard cannot commit the security perimeter again** (2026-09-13 perimeter audit).
  Between
  [#1978](https://github.com/p2pool-starter-stack/pithead/issues/1978) and this change, a
  configuration key that was on neither the freely-editable nor the confirm-gated allowlist did not
  fail closed: it asked for the approval tier instead, so that every configuration leaf had some
  route from a machine with no host shell. That tier's second identity was the Telegram tap, which
  [#2076](https://github.com/p2pool-starter-stack/pithead/issues/2076) removed — leaving the typed
  confirmation alone in it. The dashboard container writes its own request spool, so it could
  supply that confirmation itself. Payout addresses, view keys, node and stratum credentials, the
  Tor egress firewall, onion exposure, webhook and Healthchecks URLs and the control channel's own
  switch were all reachable that way. **The approval tier is now a short named list**, so a key
  nobody enumerated is refused outright again, and the perimeter [`SECURITY.md`](SECURITY.md)
  describes holds as written. The gap opened and closed inside this Unreleased section: #1978 is in
  no release tag, so no tagged release carries it. A build cut from `develop` between those two
  commits does — check the commit an RC image was built from before trusting it.
- **What this means for the Configuration view.** Settings outside the three tiers render greyed
  as host-only, as they did before #1978 — change them on the host with `./pithead apply`, or on
  an appliance with a configuration stick, which may set anything. The settings that lose their
  dashboard route include the payout addresses, the view keys, the node RPC credentials, the
  stratum password, the Telegram bot token and chat id, the XvB pool URL and donor id, the
  Healthchecks ping URL, the ntfy URL and token, `notifications.webhooks`, the onion toggles, the
  Tor egress firewall, the RPC/gRPC LAN-access and bind settings, `dashboard.control.enabled`, and
  the per-rig worker descriptors (`workers.list[]`) — an added, repointed, or removed rig host and
  API token is a credential change, closed in the same round-2 pass after an initial review found
  it still routed through the self-written approval envelope.
- The Telegram tap was the only second identity on a sensitive configuration commit, and nothing
  replaces it in this release. What still gates such a change is the signed-in dashboard operator,
  the default-deny env allowlist, the typed `APPLY`, and the payout-suffix check — deliberate
  friction and typo protection, not a second identity. The physical-presence boundary is unchanged:
  `dashboard.auth.password` and the two tamper-alarm event toggles still cannot be changed
  from the dashboard at all. See [`SECURITY.md`](SECURITY.md).

### Fixed

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

## [2.0.0] - 2026-09-06

Pithead 2.0.0 is the first release of **Pithead OS**, the appliance: a bootable image that
installs itself on a machine you dedicate to it, is set up from a browser, and updates as one
signed image that goes back to the previous version on its own when an update does not boot.
The Docker-Compose install (the DIY path) ships in the same release, with the same stack, the
same dashboard and the same configuration. Entries below apply to both channels unless they say
otherwise. The appliance guide is [`docs/appliance.md`](docs/appliance.md).

### Added

- **Pithead OS, the appliance.** Write `pithead-os-v2.0.0.img` to a USB stick and boot the machine
  from it: it installs itself and serves a one-page setup wizard to your browser. The page asks
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
  v1.17.0 ([#1826](https://github.com/p2pool-starter-stack/pithead/issues/1826)).
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

- **The two 1.x configuration aliases ([#1832](https://github.com/p2pool-starter-stack/pithead/issues/1832)).** `dashboard.workers[]` is `workers.list[]`, and
  `xmrig_proxy.{enabled,url,donor_id}` is `xvb.*`. A 1.x configuration is migrated in place once, the
  first time 2.0.0 reads it; after that the old names are unknown to the product. A configuration that
  sets an old name and its replacement to different values is refused.

### Fixed

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

Older releases (before 2.0.0) are archived in [docs/changelog-archive.md](docs/changelog-archive.md).
