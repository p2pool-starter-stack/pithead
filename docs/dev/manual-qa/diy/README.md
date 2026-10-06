# DIY route

The self-hosted (DIY) half of the manual QA checklist: the Compose stack, driven by `./pithead` and `config.json`, tested on two machines.

Sections 1–12 are written for the DIY route. Section 13 runs the [appliance route](../appliance/README.md) and repeats the DIY steps that apply there. Start with the [checklist overview](../README.md), which explains how to record results and what the words in the [glossary](../README.md#glossary) mean.

## The two DIY machines

| Machine | What it is | Where it is used |
|---|---|---|
| **Fresh box** | Ubuntu Server 24.04, AVX2 CPU, 16 GB RAM, 600 GB SSD, nothing of Pithead on it | Section 1; 10.1, 10.2 and 10.7, and the second machine in 10.3, 10.3a, 10.4 and 10.6; 11.6 and 11.7, last; 12.1 and 12.2 after 11.7, with the previous release's bundle installed |
| **Upgrade box** | A machine already running the previous release, with both chains synced and the dashboard password set | Sections 2–11; it runs the candidate from 2.2 on. Its Monero node is also the test node for 13.15 (M16), opened to the LAN as in Config D of [Sample configs](../sample-configs.md) |

Either box may be a virtual machine: [sandbox-vm.md](sandbox-vm.md) gives the spec, how to start and end one on the project's bench fleet, and what a VM cannot prove. [What you need](../what-you-need.md) lists everything else, such as the miners, the laptop, the QA wallets and the test bot.

Do not use an upgrade box whose dashboard onion address or history you need to keep: 9.5 replaces its onion address and 11.5 clears its dashboard history.

## The DIY files, in order

Run the sessions in the order of the [Run sheet](../README.md#run-sheet). Where it differs from the order of the files below, the Run sheet wins.

| File | What it tests | Machine | Run sheet session |
|---|---|---|---|
| [sandbox-vm.md](sandbox-vm.md) | Running the DIY boxes as virtual machines | Either box | Before session 2 |
| [01-fresh-install.md](01-fresh-install.md) | 1. Fresh DIY install | Fresh box | 2 (1.1–1.11), 9 (1.12, 1.13) |
| [02-upgrade.md](02-upgrade.md) | 2. Upgrade from the previous release | Upgrade box | 3 |
| [03-everyday-commands.md](03-everyday-commands.md) | 3. Everyday commands | Upgrade box | 4 |
| [04-connect-a-miner.md](04-connect-a-miner.md) | 4. Connect a miner | Upgrade box, two miners | 4 |
| [05-dashboard-tour.md](05-dashboard-tour.md) | 5. Dashboard tour | Upgrade box, laptop, phone | 4 |
| [06-settings-command-line.md](06-settings-command-line.md) | 6. Change settings from the command line | Upgrade box | 5 |
| [07-settings-dashboard.md](07-settings-dashboard.md) | 7. Change settings from the dashboard | Upgrade box | 5 |
| [08-alerts-telegram.md](08-alerts-telegram.md) | 8. Alerts and Telegram | Upgrade box, test bot | 6 |
| [09-privacy-tor.md](09-privacy-tor.md) | 9. Privacy and Tor | Upgrade box, Tor Browser | 6 (with 9.6a's DIY half; its appliance half is in session 10) |
| [10-node-and-pool-modes.md](10-node-and-pool-modes.md) | 10. Node and pool modes | Fresh box and upgrade box, a miner | 9 |
| [11-backup-restore-resets.md](11-backup-restore-resets.md) | 11. Backup, restore and resets | Upgrade box; 11.6 and 11.7 on the fresh box | 9 (11.1–11.5), 13 (11.6, 11.7 last) |
| [12-upgrade-from-dashboard.md](12-upgrade-from-dashboard.md) | 12. Upgrade from the dashboard | A DIY box on the previous release (12.1, 12.2); an appliance on the previous release (12.3) | After publishing |

The steps that destroy data (resets and uninstall) come last on purpose.
