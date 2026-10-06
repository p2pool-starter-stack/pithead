# 4. Connect a miner

This part tests connecting XMRig miners to the stack: plain [stratum](../README.md#glossary), a wrong password, TLS, a second worker and the per-worker details.

## Before you start

- **Machines:** the **upgrade box**, and two miner machines running XMRig (4.4 needs the second). Your own PCs are fine: nothing in this section changes them.
- **Earlier steps:** section 3, so 2.3a is done. This is part of session 4 of the [Run sheet](../README.md#run-sheet).
- **Have ready:** the upgrade box's LAN IP address; the laptop, logged in to the dashboard; [Connecting Miners](../../../workers.md) for how to point XMRig at a pool.
- **Time:** roughly 1 hour.

### Get the stratum password

4.2 needs a stratum password, and the miner's pool entry in 4.1 uses it.

1. On the upgrade box, read it:

   ```bash
   grep PROXY_STRATUM_PASSWORD .env
   ```

2. If the value is empty (a box that never had one; a new install has none unless its [wizard](../README.md#glossary) was told to), add `"stratum_password": "auto"` inside the `p2pool` block of `config.json`, then apply it, and read the password again with the `grep` above:

   ```bash
   ./pithead apply
   ```

## Steps

### 4.1 Plain stratum

**What you do:**

1. On the first miner machine, point XMRig at the stack, using [Connecting Miners](../../../workers.md). Put this pool entry in XMRig's config, with `<stack IP>` replaced by the upgrade box's LAN IP address and `<stratum password>` by the password from "Get the stratum password":

   ```json
   { "pools": [ { "url": "<stack IP>:3333", "user": "qa-rig-01", "pass": "<stratum password>" } ] }
   ```

2. Start XMRig and watch its log.
3. On the laptop, watch the dashboard's **Workers Alive** table.

**What you should see:**

- XMRig logs `accepted` shares within a few minutes.
- `qa-rig-01` appears in the dashboard's **Workers Alive** table within a minute (the page refreshes every 30 seconds).

**Record**: PASS, FAIL or N/A in the results sheet.

### 4.2 Wrong password

**What you do:**

1. In XMRig's pool entry, change `pass` to something wrong.
2. Restart XMRig.
3. Check the miner's log and the **Workers Alive** table.
4. Put the right password back, and restart XMRig.

**What you should see:**

- The stack rejects the miner.
- It does not appear in **Workers Alive**.

**Record**: PASS, FAIL or N/A in the results sheet.

### 4.3 TLS

**What you do:**

1. On the upgrade box, set `"stratum_tls": true` inside the `p2pool` block of `config.json`.
2. Apply it:

   ```bash
   ./pithead apply
   ```

3. Copy the fingerprint it prints. `./pithead status` also shows it.
4. In the miner's pool entry, add `"tls": true` and `"tls-fingerprint": "<fingerprint>"`, with `<fingerprint>` replaced by the fingerprint you copied.
5. Restart XMRig.

**What you should see:**

- The miner connects over TLS and mines.
- A miner without `tls` keeps mining in cleartext on the same port.

**Record**: PASS, FAIL or N/A in the results sheet.

### 4.4 Second worker

**What you do:**

1. On the second miner machine, start a miner with `"user": "qa-rig-02"`.

**What you should see:**

- Two rows in **Workers Alive**.
- The total hashrate is about the sum of the two.

**Record**: PASS, FAIL or N/A in the results sheet.

### 4.5 Worker drill-down

**What you do:**

1. On the dashboard, look at each row in **Workers Alive**.

**What you should see:**

- Each row shows IP, uptime, hashrate and accepted/rejected shares.
- A RigForge [rig](../README.md#glossary) also shows its chips (thermals, governor) and version.

**Record**: PASS, FAIL or N/A in the results sheet.
