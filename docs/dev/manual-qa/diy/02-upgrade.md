# 2. Upgrade from the previous release

This part tests an upgrade from the previous release to the candidate: nothing is lost, 1.x config keys are migrated, and the one-way Tari migration finishes on its own.

## Before you start

- **Machine:** the **upgrade box**, which runs the previous release with [synced](../README.md#glossary) chains (full spec in [What you need](../what-you-need.md)). It may be a virtual machine: see [sandbox-vm.md](sandbox-vm.md), and start from its *previous release synced* snapshot.
- **Earlier steps:** none on this box. This is session 3 of the [Run sheet](../README.md#run-sheet).
- **Have ready:** the candidate's full commit SHA; a USB disk or a NAS for the backup; the laptop; the private handoff for passphrases and notes.
- **Time:** about 1 hour hands-on, and a wait of about 3 hours for the Tari migration in 2.3a.

### Write down the box's state first

Before step 2.1, write down the following, and take a screenshot of the hashrate chart:

- the payout addresses;
- the dashboard login;
- the dashboard's [onion](../README.md#glossary) address, if the onion is on (`./pithead status` prints it);
- the worker count;
- whether XvB is on;
- Tari's mode;
- whether a [stratum](../README.md#glossary) password is set (`grep PROXY_STRATUM_PASSWORD .env` shows an empty value when none is);
- whether payout confirmation is on (`monero.view_key` set).

### Upgrading from 1.x.x

An upgrade from 1.x.x keeps `config.json` as faithfully as it can. A key the old file lacked (`xvb.enabled`, `tari.mode`, `p2pool.stratum_password`, a dashboard login) behaves as it did on 1.x, because the new-install defaults of #3099 come only from the [wizards](../README.md#glossary). Config versioning starts with 2.0.0 and has no 1.x migration (#3109).

If the upgrade refuses or misreads a 1.x config, the 2.0.0 release notes say so: a fresh setup may be required when upgrading from 1.x.x. In that case:

1. Record what broke.
2. Take a backup.
3. Run setup again.
4. Carry on from 2.3 on the fresh config.

## Steps

### 2.1 Backup first

**What you do:**

1. Take a backup with the chains included, as the 2.0.0 upgrading notes ask, because the Tari migration in 2.2 is one-way:

   ```bash
   ./pithead backup --with-chains
   ```

2. Choose a passphrase when asked, and keep it in the private handoff.
3. Answer `y` to `Stop the stack, back up, then start it again?`.
4. Look in the `backups/` folder for the new file.
5. Move the archive off the box (to a USB disk or a NAS) before 2.2. Left in `backups/` on the data disk, it can take the free space the Tari migration needs, and 2.2 then refuses (2.2a).
6. You also need a plain `./pithead backup` for 13.14a. 2.1b says when to take it.

**What you should see:**

- A file `backups/pithead-backup-<date>-<time>.tar.gz.enc` exists, where `<date>` and `<time>` are when you took it.
- The stack was stopped for the copy and is running again.

**Record**: PASS, FAIL or N/A in the results sheet. Keep the passphrase in the private handoff.

### 2.1b 1.x config keys are migrated

**What you do:**

Do items 1–9 on the previous release, after you wrote down the box's state above.

1. Check for legacy workers:

   ```bash
   jq -c '.dashboard.workers' config.json
   ```

   If this prints anything other than `null`, `dashboard.workers` already exists. Then record 2.1b BLOCKED for this upgrade session and keep the config unchanged: it already carries legacy workers this fixture must not overwrite. Skip items 2–7 and 11–13, but still take the plain backup in items 8 and 9.
2. Check whether `workers.list` exists:

   ```bash
   jq -c '.workers.list' config.json
   ```

   If it prints `null`, there is no `workers.list`. If it prints anything else, including an empty `[]`, save that output with your private notes. This output can contain [rig](../README.md#glossary) addresses and tokens: never attach it publicly.
3. Without [applying](../README.md#glossary), edit `config.json`. If the `xvb` block has an `enabled` key, delete that key first.
4. Add a top-level `"xmrig_proxy": { "enabled": false }`.
5. If there is no `workers.list`, add `"workers": [ { "name": "qa-1x-migration" } ]` inside the `dashboard` block.
6. If there is a `telegram` block, add `"control": { "enabled": true }` inside it.
7. Run the duplicate-key check from [Sample configs](../sample-configs.md#sample-configs). It must print `config.json OK`:

   ```bash
   python3 -c 'import json; json.load(open("config.json"), object_pairs_hook=lambda kv: exit("duplicate key: " + str([k for k, _ in kv])) if len(kv) != len(dict(kv)) else dict(kv)); print("config.json OK")'
   ```

8. Take a plain backup:

   ```bash
   ./pithead backup
   ```

9. Copy that backup to the laptop with `scp`, and keep it, with its passphrase, for 13.14a.
10. Go on with 2.2a and 2.2. Watch the output of the first `./pithead upgrade` that runs, then come back here.
11. After the upgrade (2.2), show the migrated keys:

    ```bash
    jq '{xvb, workers, tc: .telegram.control}' config.json
    ```

12. Check the old copy exists:

    ```bash
    ls config.json.bak-1x
    ```

13. If you saved a `workers.list` line in item 2, print it again and compare it with the saved line:

    ```bash
    jq -c '.workers.list' config.json
    ```

**What you should see:**

- The first `./pithead upgrade` that runs (2.2a or 2.2) prints `[pithead] Migrated the 1.x config keys (dashboard.workers[] to workers.list[], xmrig_proxy.* to xvb.*) — the old copy is at config.json.bak-1x.`, in all three cases (absent, empty or populated `workers.list`).
- With the `telegram` block, it also prints the warning `telegram.control was removed: the Telegram bot is read-only now.`
- The `jq` output shows `"enabled": false` under `xvb`, and `"tc": null`.
- `qa-1x-migration` appears under `workers.list` only if this step added it.
- Otherwise, `jq -c '.workers.list' config.json` matches the saved line byte for byte, whether the list was empty or populated.
- `config.json.bak-1x` exists.
- A later dashboard save (7.2) is not refused for a leftover key (you check this in 7.2).

**Record**: PASS, FAIL or N/A in the results sheet, or BLOCKED when `dashboard.workers` already existed. The saved `workers.list` line goes in your private notes only.

### 2.2a The upgrade refuses a Tari volume without room

**What you do:**

Upgrade box only, before 2.2, with the stack running.

1. Check the stack is running: `docker ps` must list the `tari` container.
2. Run the first 2.2 commands, but not `./pithead upgrade` yet. Replace `<full candidate SHA>` with the candidate's full commit SHA:

   ```bash
   git fetch
   git checkout <full candidate SHA>
   make
   ```

3. Find the directory that `tari.data_dir` names in `config.json` (`data/tari` when it is unset). Below, `<that directory>` stands for it.
4. Find the node database, the `data.mdb` under `…/base_node/db/` inside that directory, and note its size:

   ```bash
   sudo find <that directory> -path '*/base_node/db/data.mdb' -exec ls -l {} +
   ```

5. Find the free space on its volume:

   ```bash
   df -BG <that directory>
   ```

6. If the stack reports disk or write errors at any point while the filler below exists, remove the filler first.
7. On that same volume, create a filler file so that the free space drops below the size of `data.mdb` plus 5 GiB. `<free − data.mdb size − 2>` is the free GiB from item 5, minus the size of `data.mdb` in GiB, minus 2; for example, with 100 GiB free and a 40 GiB `data.mdb`, use `58`. `<a directory on that volume>` is any directory on the same volume as `<that directory>`. For example:

   ```bash
   sudo fallocate -l <free − data.mdb size − 2>G <a directory on that volume>/qa-filler
   ```

8. Check the free space again:

   ```bash
   df -BG
   ```

9. Run the upgrade at once:

   ```bash
   ./pithead upgrade
   ```

10. Remove the filler at once:

    ```bash
    sudo rm <a directory on that volume>/qa-filler
    ```

11. If `./pithead upgrade` did not refuse, remove the filler immediately, touch nothing else, and go on with 2.3a: the migration has started.
12. Check the containers:

    ```bash
    docker ps
    ```

**What you should see:**

- `./pithead upgrade` stops with `Refusing the upgrade: Tari 5 → 6 migrates the node database by writing a compacted copy beside the old one, which needs`, followed by the GiB needed and free on the volume.
- It ends with `No container was changed.`
- `docker ps` still shows the previous release's containers running.
- After the filler is gone, 2.2 goes ahead.

**Record**: PASS, FAIL or N/A in the results sheet.

### 2.2 Upgrade

**What you do:**

On a source checkout (if you did 2.2a, the first three commands are already done):

1. Fetch the new code:

   ```bash
   git fetch
   ```

2. Switch to the candidate. Replace `<full candidate SHA>` with the candidate's full commit SHA:

   ```bash
   git checkout <full candidate SHA>
   ```

3. Build it:

   ```bash
   make
   ```

4. Upgrade:

   ```bash
   ./pithead upgrade
   ```

On a release-bundle install, use the bundle command in [Operations › Updating the stack](../../../operations.md#updating-the-stack) instead, once the candidate is published.

**What you should see:**

- It finishes without errors.
- It recreates only what changed.

**Record**: PASS, FAIL or N/A in the results sheet.

### 2.3 Nothing lost

**What you do:**

1. Compare the box with the notes you wrote down before 2.1.
2. Show the version:

   ```bash
   ./pithead version
   ```

3. Print the config version stamp:

   ```bash
   jq -r .config_version config.json
   ```

4. Check the file's permissions and owner:

   ```bash
   ls -l config.json
   ```

**What you should see:**

- `./pithead version` shows the candidate.
- The dashboard login, payout addresses, onion address and worker list match your notes, with `qa-1x-migration` as the one expected extra `workers.list` entry only if 2.1b inserted it. Otherwise the worker list matches your notes exactly.
- When 2.1b ran, XvB is off, because 2.1b deliberately set `xmrig_proxy.enabled` to `false`, which migrates to `xvb.enabled: false`. If that fixture was BLOCKED, XvB matches your original notes.
- Tari's mode and the stratum password setting are as you noted, because an upgrade keeps what it had (#3099).
- The hashrate chart still shows the history from before.
- Monero is still synced, and the miners reconnected by themselves.
- Per #3109, the `jq` line prints the candidate's release number without any `-pre` or build suffix.
- `config.json` is still `-rw-------`, with its owner unchanged.
- If payout confirmation was on before the upgrade, the payout card is green again with no rescan: #3096 adopts the old wallet as the one for your current address and [view key](../README.md#glossary).
- Tari reads loading, with no progress, until its one-way database migration ends (2.3a). That is expected for hours, not a failure.

**Record**: PASS, FAIL or N/A in the results sheet.

### 2.3a Wait out the Tari migration and the fork rewind

**What you do:**

Do not run any command that stops or recreates a container (`restart`, `down`, `up`, `apply`, `upgrade`, `backup`, a reboot) during this step. A stopped Tari container is killed one minute after the stop, and an interrupted migration loses the Tari database with no way back. `./pithead status`, `./pithead doctor` and `docker logs` only read, so they are safe.

1. Right after 2.2, follow the Tari log in its own terminal window, and leave the box alone:

   ```bash
   docker logs -f tari
   ```

2. Note the time each of these log lines appears, in this order:
   - `[MIGRATIONS] Blockchain database is at v6`
   - `v6: Starting JMT v1 → v2 rebuild`
   - `JMT rebuild complete`
   - `Compacting LMDB env`
   - then the `[pithead fork-check]` lines.
3. Every 30 minutes, look at the dashboard's Tari card and, in a second terminal window, run:

   ```bash
   ./pithead status
   ```

4. Each time, also check that `xmrig-proxy` is running:

   ```bash
   docker ps
   ```

**What you should see:**

- For about two and a half hours the Tari card reads loading with no progress, and the log shows the phases in the order above.
- When the migration ends, the fork check prints either `[pithead fork-check] header 350000 is canonical (…); nothing to rewind`, or `… dead 5.3.1 branch` followed by `stopping the node to rewind to 349900`, `rewound to …` and `starting the node normally`.
- No `[pithead fork-check] ERROR:` line appears.
- Tari then catches up to the tip, and the Tari card shows its progress again.
- Per #3091, a migrating or starting node is never down: `docker ps` shows `xmrig-proxy` running throughout.
- No `Tari DOWN` or `Workers rejected` badge shows.
- If the box already has Telegram set up, a message that starts `Tari node is migrating` or `Tari node is starting` arrives instead.

**Record**: PASS, FAIL or N/A in the results sheet, and write down the time of each log line from item 2.

### 2.4 Health after upgrade

**What you do:**

Run this only once 2.3a has ended and Tari is at the tip.

1. Show the status:

   ```bash
   ./pithead status
   ```

2. Run the health check:

   ```bash
   ./pithead doctor
   ```

**What you should see:**

- All healthy.
- No FAIL.

**Record**: PASS, FAIL or N/A in the results sheet.
