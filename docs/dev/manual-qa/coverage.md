# Coverage

Which steps check each feature on the self-hosted (DIY) route and on the appliance route, and
which steps prove each issue the 2.0.0 re-cut fixed or added.

## Before you start

- Which machine: none. Nothing here is run; use the tables to find the steps for a feature or a
  fix. Every step number links to the file that holds it.
- Rough time: a few minutes to read.

## Route coverage

Pithead ships two ways: the self-hosted (DIY) Compose stack, driven by `./pithead` and
`config.json`, and the appliance, driven by its setup page, dashboard, boot menu and USB stick.
Every feature is checked on both routes, or the table says why one route has nothing to check.
Sections 1–12 are written for the DIY route; section 13 runs the appliance route and repeats the
DIY steps that apply there.

| Feature | Self-hosted (DIY) | Appliance |
|---|---|---|
| Install | [1.1–1.9, 1.4a](diy/01-fresh-install.md) | [13.1–13.7, 13.6a, 13.7a](appliance/13a-install-and-first-boot.md) |
| First [sync](README.md#glossary) and Sync Mode | [1.6–1.13](diy/01-fresh-install.md) | [13.8](appliance/13a-install-and-first-boot.md) (repeats 1.8 and 1.13) |
| Upgrade from the previous release | [2.1–2.4](diy/02-upgrade.md), [12.1–12.2](diy/12-upgrade-from-dashboard.md) | [12.3](diy/12-upgrade-from-dashboard.md), [13.10](appliance/13b-updates-restore-and-media.md) |
| Everyday commands | [3.1–3.7](diy/03-everyday-commands.md) | No shell. The health check and recent log ([7.7](diy/07-settings-dashboard.md), through [13.8](appliance/13a-install-and-first-boot.md)) and the boot menu ([13.9](appliance/13a-install-and-first-boot.md)) stand in. |
| Miners | [4.1–4.5](diy/04-connect-a-miner.md) | [13.8](appliance/13a-install-and-first-boot.md) (repeats section 4), [14.1–14.4](appliance/14-rigforge-rig.md) |
| Mining on the stack machine itself | [6.9](diy/06-settings-command-line.md) | [13.8](appliance/13a-install-and-first-boot.md) (the built-in miner), [13.8a](appliance/13a-install-and-first-boot.md) |
| Dashboard | [5.1–5.12](diy/05-dashboard-tour.md) | [13.8](appliance/13a-install-and-first-boot.md) (repeats section 5) |
| Settings | [6.1–6.10](diy/06-settings-command-line.md), [7.1–7.9](diy/07-settings-dashboard.md) | [13.8](appliance/13a-install-and-first-boot.md) (repeats 7.1–7.9), [13.15, 13.23, 13.24](appliance/13b-updates-restore-and-media.md) |
| Alerts and Telegram | [8.1–8.7](diy/08-alerts-telegram.md) | [13.8](appliance/13a-install-and-first-boot.md) (repeats 8.2–8.4) |
| Privacy and [Tor](README.md#glossary) | [1.10](diy/01-fresh-install.md), [9.1–9.8](diy/09-privacy-tor.md) | [9.6a](diy/09-privacy-tor.md), [13.20, 13.21](appliance/13b-updates-restore-and-media.md) |
| Node and pool modes | [10.1–10.7](diy/10-node-and-pool-modes.md) | [13.15, 13.22](appliance/13b-updates-restore-and-media.md) |
| Backup and restore | [11.1–11.4](diy/11-backup-restore-resets.md), [S5](release/scenarios.md) | [13.13, 13.14, 13.14a](appliance/13b-updates-restore-and-media.md) |
| Resets and removal | [11.5–11.7](diy/11-backup-restore-resets.md) | [15.2, 15.3](appliance/15-rename-and-resets.md) |
| Power loss | [S3](release/scenarios.md) | [13.19](appliance/13b-updates-restore-and-media.md) |
| Machine name | [1.4](diy/01-fresh-install.md) (the hostname prompt) | [15.1](appliance/15-rename-and-resets.md) |
| Headless setup and recovery | Not applicable: a DIY host has its own shell. | [13.16, 13.17, 13.23](appliance/13b-updates-restore-and-media.md) |
| [Rigs](README.md#glossary) | Not applicable: a DIY rig is a RigForge install, tested in that project. | [14.1–14.4](appliance/14-rigforge-rig.md) |

## Re-cut coverage

Which steps prove each issue the 2.0.0 re-cut fixed or added. **Shipped** means the
**What you should see** lines quote merged code; every row is shipped.

| Issue | What it requires | Steps | Wording |
|---|---|---|---|
| [#3090](https://github.com/p2pool-starter-stack/pithead/issues/3090) | `setup`, `up` and [`apply`](README.md#glossary) always print the pool URL and the [stratum](README.md#glossary) password (`none set` when there is none); a toggle-only `apply` still converges the local miner | [1.4, 1.5](diy/01-fresh-install.md), [6.9](diy/06-settings-command-line.md), [13.8a](appliance/13a-install-and-first-boot.md) | Shipped (#3101) |
| [#3091](https://github.com/p2pool-starter-stack/pithead/issues/3091) | A required Tari rejects workers only after its RPC has been unreachable 10–15 minutes (15 shipped); migrating, starting and syncing only alert; Tari alerts ignore `tari_required`; an unreachable Monero node, local or remote, always rejects | [1.12](diy/01-fresh-install.md), [2.3a](diy/02-upgrade.md), [8.5](diy/08-alerts-telegram.md), [10.5, 10.6](diy/10-node-and-pool-modes.md) | Shipped (#3093) |
| [#3092](https://github.com/p2pool-starter-stack/pithead/issues/3092) | The stratum password is opt-in (default off) in both [wizards](README.md#glossary) and shows on the hand-off card, in **Connect a miner** and in CLI output, also on a LAN dashboard with no login; an [onion](README.md#glossary) dashboard always has a login | [1.4, 1.4a](diy/01-fresh-install.md), [5.12](diy/05-dashboard-tour.md), [10.7](diy/10-node-and-pool-modes.md), [13.6, 13.6a, 13.8](appliance/13a-install-and-first-boot.md), last row of [Broken configs](sample-configs.md#broken-configs) | Shipped (#3107) |
| [#3094](https://github.com/p2pool-starter-stack/pithead/issues/3094) | Enabling Tari on a box that is already mining keeps Monero mining while Tari syncs | [10.2](diy/10-node-and-pool-modes.md), [13.22](appliance/13b-updates-restore-and-media.md) | Shipped (#3102) |
| [#3096](https://github.com/p2pool-starter-stack/pithead/issues/3096) and [#2732](https://github.com/p2pool-starter-stack/pithead/issues/2732) | One view-only wallet per (address, [view key](README.md#glossary)), adopted on upgrade; a fresh wallet starts near the tip; a key that does not match the address is refused; Tari confirmation needs a dual-key address and asks for the view key only | [2.3](diy/02-upgrade.md), [6.4a, 6.4b](diy/06-settings-command-line.md), [7.5](diy/07-settings-dashboard.md) | Shipped (#3113) |
| [#3097](https://github.com/p2pool-starter-stack/pithead/issues/3097) | A payout-address change is confirmed by typing its last 8 characters, everywhere | [6.4](diy/06-settings-command-line.md), [7.5](diy/07-settings-dashboard.md), [13.8](appliance/13a-install-and-first-boot.md) | Shipped (#3105) |
| [#3098](https://github.com/p2pool-starter-stack/pithead/issues/3098) | `apply` and the dashboard refuse duplicate JSON keys and `PASTE_` or `YOUR_` values | [Broken configs](sample-configs.md#broken-configs), [6.5](diy/06-settings-command-line.md), [7.6](diy/07-settings-dashboard.md) | Shipped (#3106) |
| [#3099](https://github.com/p2pool-starter-stack/pithead/issues/3099) | New-install defaults in both wizards: Tari off unless opted in (#3333), XvB off and not asked, a generated dashboard login, Tor first sync with an opt-in fast sync that warns; upgrades keep their config | [1.4, 1.4a](diy/01-fresh-install.md), [2.3](diy/02-upgrade.md), [7.3a](diy/07-settings-dashboard.md), [13.6, 13.6a](appliance/13a-install-and-first-boot.md) | Shipped (#3110) |
| [#3109](https://github.com/p2pool-starter-stack/pithead/issues/3109) | A host-owned `config_version` stamp, hidden and not editable in Configuration; only a newer config warns; a restore of a newer config is refused; the 1.x release-notes line | [1.4a](diy/01-fresh-install.md), [2.3](diy/02-upgrade.md), [6.10](diy/06-settings-command-line.md), [7.1, 7.1a](diy/07-settings-dashboard.md), [11.2a](diy/11-backup-restore-resets.md), and the 1.x note in [section 2](diy/02-upgrade.md) | Shipped (#3114) |
| [#3112](https://github.com/p2pool-starter-stack/pithead/issues/3112) | Docs for getting the view keys from the Monero GUI wallet and Tari Universe | [7.9](diy/07-settings-dashboard.md) | Shipped (#3168) |
| [#3100](https://github.com/p2pool-starter-stack/pithead/issues/3100) | Appliance docs corrections | [12.3](diy/12-upgrade-from-dashboard.md), [13.10, 13.21, 13.25](appliance/13b-updates-restore-and-media.md), [15.1](appliance/15-rename-and-resets.md) | Shipped (#3104) |
| [#3116](https://github.com/p2pool-starter-stack/pithead/issues/3116) | The image pins RigForge at the develop tip that becomes v1.18.0 | [13.7a, 13.8](appliance/13a-install-and-first-boot.md), [14.1](appliance/14-rigforge-rig.md) | Shipped (#3117) |
| [#3118](https://github.com/p2pool-starter-stack/pithead/issues/3118) | Tor recovers from a saturated circuit-build state: early alert, self-heal under `tor.auto_heal`, advice and doctor name `tor-recover` | [9.6a](diy/09-privacy-tor.md) | Shipped (#3120) |

No step re-points Tari at another node (#3094) or changes a Tari payout address (#3097): both
need equipment that [What you need](what-you-need.md) does not list, a second Tari node and a
second Tari QA wallet.
