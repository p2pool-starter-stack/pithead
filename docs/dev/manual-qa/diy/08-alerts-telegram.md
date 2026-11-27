# 8. Alerts and Telegram

This part checks the Telegram bot: the test alert, the read-only commands, worker and node alerts, the daily summary and the online message.

## Before you start

- Machine: the **upgrade box**, in a terminal in the install directory, with the dashboard open on the laptop.
- Earlier steps: sections 2 to 7. Both miners from [Connect a miner](04-connect-a-miner.md) are mining, including `qa-rig-02` from 4.4.
- Have ready:
  - The Telegram test bot: its token, and the chat id of the test chat. See [Telegram](../../../telegram.md).
  - A second Telegram chat that is not configured for the bot, for 8.3.
- Time: about 1 hour. It is part of session 6 in the [Run sheet](../README.md#run-sheet).

## Set up the bot

1. Copy the `telegram` block from [Config B](../sample-configs.md) into the upgrade box's `config.json` as a top-level block. If there is already a `telegram` block, replace it.
2. Fill in the bot token and the chat id.
3. Run `./pithead apply` (see [apply](../README.md#glossary)).

## Steps

### 8.1 Test alert

**What you do:**

1. Run:

   ```bash
   ./pithead test-alert
   ```

**What you should see:**

- One marked test message arrives in the test chat.
- The command reports each sink's result (each place an alert is sent, such as Telegram) without printing the token.

**Record:** PASS, FAIL or N/A in the results sheet.

### 8.2 Commands

**What you do:**

1. In the test chat, send each of these commands: `/help`, `/status`, `/info`, `/hashrate`, `/workers`, `/sync`, `/system`, `/pool`, `/xvb`, `/earnings` and `/luck`.
2. Compare the numbers in the replies with the dashboard.
3. On the upgrade box, run `docker ps` and note the uptimes.
4. Send `/restart`, then `/apply`. 2.0.0 removed both commands.
5. Run `docker ps` again, and look at **Recent config changes** in the dashboard.

**What you should see:**

- Each command in item 1 gets a reply.
- The numbers agree with the dashboard.
- `/restart` and `/apply` each get `Unknown command.` and the help text.
- Nothing restarts or applies: the `docker ps` uptimes are unchanged, and **Recent config changes** has no new row.

**Record:** PASS, FAIL or N/A in the results sheet.

### 8.3 Other chats are ignored

**What you do:**

1. Message the bot from a chat that is not configured.

**What you should see:**

- No reply.

**Record:** PASS, FAIL or N/A in the results sheet.

### 8.4 Worker offline

**What you do:**

1. Stop the miner `qa-rig-02`.
2. Wait 6 minutes.
3. Start it again, and wait a few minutes.

**What you should see:**

- A worker-offline message arrives after about 5 minutes.
- The row is badged offline on the dashboard.
- A back-online message arrives about 2 minutes after the miner reconnects.

**Record:** PASS, FAIL or N/A in the results sheet.

### 8.5 Node down

**What you do:**

1. Run this, then wait 2 minutes, watching the dashboard, the test chat and a miner's XMRig log:

   ```bash
   docker stop monerod
   ```

2. Run:

   ```bash
   ./pithead up
   ```

**What you should see:**

- The dashboard shows the `monerod DOWN` badge after about 90 seconds, then a `Workers rejected` badge.
- A node-down message arrives: `Monero node is DOWN — workers failing over to backup pools.`
- xmrig-proxy is stopped, so XMRig logs that it lost the pool. With a backup pool in its config, it would switch to it.
- After `./pithead up`, the badges clear.
- A node-recovered message arrives: `Monero node recovered — workers readmitted.`
- The miners reconnect.

Monero always alerts and always rejects, local or remote ([10.6](10-node-and-pool-modes.md#106-remote-monero-node-outage)). The Tari outage alert, which does not depend on `tari_required` (#3091), is checked in [10.5](10-node-and-pool-modes.md#105-tari-outage).

**Record:** PASS, FAIL or N/A in the results sheet.

### 8.6 Daily summary

**What you do:**

1. Set `telegram.daily_summary_time` a few minutes ahead of the current time. It is a 24-hour `HH:MM` local time; see [Configuration](../../../configuration.md).
2. Run `./pithead apply`.
3. Wait until that time.

**What you should see:**

- The summary arrives at that time, with the 24h hashrate and earnings.

**Record:** PASS, FAIL or N/A in the results sheet.

### 8.7 Stack online

**What you do:**

1. Run:

   ```bash
   ./pithead restart
   ```

**What you should see:**

- One "Pithead online" message arrives when the dashboard is back.

**Record:** PASS, FAIL or N/A in the results sheet.
