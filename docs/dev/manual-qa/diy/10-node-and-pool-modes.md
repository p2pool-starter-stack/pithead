# 10. Node and pool modes

This part checks switching Tari off and on, sharing one Monero node between two machines, refusals for a bad remote node, what happens to miners when a Tari or Monero node goes down, and a dashboard with no login.

## Before you start

- Machines: the **fresh box** and the **upgrade box**, each in a terminal in its install directory, and a miner.
- Earlier steps: the fresh box has finished its first [sync](../README.md#glossary) ([section 1](01-fresh-install.md), 1.13). The Telegram test chat from [section 8](08-alerts-telegram.md) is set up on the upgrade box, for 10.3a and 10.5.
- Have ready: [Config C and Config D](../sample-configs.md) from the sample configs, filled in with your QA values, and the dashboard password used so far.
- In 10.3 to 10.6 the upgrade box is the **node machine** and the fresh box is the **second machine**, which uses the node machine's Monero node.
- Each change goes through [apply](../README.md#glossary), which prints a [preview](../README.md#glossary) first. A `⚠` line asks `(y/N)` before it changes anything.
- Time: about 2.5 hours. It is part of session 9 in the [Run sheet](../README.md#run-sheet).

## Steps

### 10.1 Monero only

**What you do:**

1. On the fresh box, replace `config.json` with Config C. Use the same dashboard password as before.
2. Run `./pithead apply`.
3. Answer `y`.
4. Run `docker ps` and look at the dashboard.

**What you should see:**

- The preview marks `Tari merge-mining OFF` with `⚠`, says its chain data is kept, and asks `(y/N)`.
- Afterwards no `tari` container runs.
- Mining continues.
- The five XvB raffle tiles are gone from the dashboard.

**Record:** PASS, FAIL or N/A in the results sheet.

### 10.2 Back to Tari

**What you do:**

1. Set `tari.mode` back to `local` and run `./pithead apply`.
2. Answer `y`.
3. Watch `docker ps` and a miner's log while Tari catches up.

**What you should see:**

- The preview marks `Tari merge-mining ON` with `⚠` and asks `(y/N)`.
- Per #3094, its row says that Monero mining continues and that merge-mining starts when Tari has synced (on an already-mining machine).
- The Tari node resumes from the chain it already had, instead of starting from zero.
- `xmrig-proxy` and p2pool stay up.
- The miners keep hashing.
- No `Workers rejected` badge shows.
- The Tari card reads syncing until Tari is at the tip.

Only a first install waits for both chains.

**Record:** PASS, FAIL or N/A in the results sheet.

### 10.3 Remote Monero node

**What you do:**

1. On the upgrade box (the node machine), add the two Config D keys inside its `monero` block and run `./pithead apply`. The preview flags them ⚠ and asks first; answer `y`.
2. On the fresh box (the second machine), replace `config.json` with Config D's second-machine file, filled in as [Config D](../sample-configs.md) says, and run `./pithead apply`. The node endpoint change is also marked ⚠ and asks `(y/N)`; answer `y`.
3. Point a miner at the second machine.

**What you should see:**

- On the second machine, no monerod container runs.
- The second machine's dashboard says the node is remote.
- Its topology labels the node LAN.
- Mining works.

**Record:** PASS, FAIL or N/A in the results sheet.

### 10.3a The LAN-published node survives a reboot

**What you do:**

1. On the node machine, with the 10.3 keys on, run:

   ```bash
   systemctl is-enabled pithead-lan-guard.service pithead-lan-hold.service pithead-egress.service
   ```

2. Then run:

   ```bash
   docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' monerod
   ```

3. Run `sudo reboot` and touch nothing.
4. When the node machine is back, look at the second machine's dashboard.
5. On the node machine, run `docker kill monerod` and wait 5 minutes.
6. Run `./pithead doctor`.
7. Finally, run `./pithead up`.

**What you should see:**

- All three units are `enabled`.
- The restart policy is `no`.
- After the reboot, monerod starts by itself, without `./pithead up`.
- The second machine reconnects and mines within minutes.
- After `docker kill`, Docker does not restart monerod.
- doctor and the dashboard say that monerod is down, and the node-down alert arrives.
- `./pithead up` brings it back, and the second machine mines again.

**Record:** PASS, FAIL or N/A in the results sheet.

### 10.4 Bad remote node

**What you do:**

1. On the second machine, with the Configuration view on, change the Monero node host to a LAN address where nothing listens, and click **Save & preview changes**.
2. Repeat with a public IP address.
3. Repeat with a misspelt hostname.

**What you should see:**

- The LAN address is refused with a reason that names the problem (nothing answering), and nothing is applied.
- The public IP address is refused because the firewall allows only private addresses.
- The misspelt hostname is reported as a name that does not resolve, not as a firewall problem.

**Record:** PASS, FAIL or N/A in the results sheet.

### 10.5 Tari outage

**What you do:**

1. On the upgrade box, leave `dashboard.tari_required` at its default (`true`).
2. Run `docker stop tari` and wait 20 minutes, watching the dashboard, the test chat and a miner's log.
3. Run `./pithead up`.
4. Add `"tari_required": false` inside the `dashboard` block and run `./pithead apply`.
5. Repeat items 2 and 3.
6. Remove the `tari_required` key afterwards.

**What you should see:**

Per #3091, with `tari_required` true:

- The Tari panel reports the node unreachable within minutes.
- The miners keep mining at the 10-minute mark.
- After 15 minutes of unreachable Tari RPC, the `Tari DOWN` and `Workers rejected` badges show.
- A node-down alert arrives.
- The workers are rejected: xmrig-proxy is stopped, so XMRig logs that it lost the pool.
- After `./pithead up` and 60 seconds of confirmed reachability, the workers are readmitted and mine again, and a node-recovered alert arrives.

With `tari_required` false:

- The `Tari DOWN` badge and the alert arrive at the same 15 minutes.
- No worker is rejected: the miners keep mining Monero throughout, and xmrig-proxy stays up.
- If the alert text says that workers are failing over to backup pools while `tari_required` is false, file it: they are not.

**Record:** PASS, FAIL or N/A in the results sheet.

### 10.6 Remote Monero node outage

**What you do:**

1. Make sure the second machine is on Config D ([10.3](#103-remote-monero-node)) and a miner is pointed at it.
2. On the node machine, run `docker stop monerod` and wait 5 minutes.
3. Look at the second machine's dashboard and the miner's log.
4. On the node machine, run `./pithead up`.

**What you should see:**

Per #3091, an unreachable Monero node, local or remote, always rejects workers:

- The second machine shows the `monerod DOWN` and `Workers rejected` badges.
- It stops its xmrig-proxy, and XMRig logs that it lost the pool.
- After `./pithead up` on the node machine, the workers are readmitted and mine again.

**Record:** PASS, FAIL or N/A in the results sheet.

### 10.7 A dashboard with no login

**What you do:**

1. On the fresh box, keep a copy of `config.json`, for example:

   ```bash
   cp config.json config.json.qa
   ```

2. Disable `dashboard.onion.enabled` if it is on, then remove the `dashboard.auth` and
   `dashboard.control` blocks.
3. Run `./pithead apply`, and answer `y` to what it asks.
4. Open the dashboard in a private window.
5. Put the copy back and run `./pithead apply`.

**What you should see:**

Per #3092:

- No login prompt appears.
- The **Connect a miner** block shows the LAN pool URL and the [stratum](../README.md#glossary) password, or `No stratum password`, to anyone on the LAN. The owner accepts that risk.

A dashboard published as an [onion](../README.md#glossary) always has a login: the last row of [Broken configs](../sample-configs.md#broken-configs) tests that read-only refusal with `apply --dry-run`. Normal apply generates a login
password before confirmation; the separate [password-generation cases](../sample-configs.md#onion-password-generation-on-normal-apply)
check cancellation and acceptance.

**Record:** PASS, FAIL or N/A in the results sheet.
