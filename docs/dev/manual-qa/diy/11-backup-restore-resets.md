# 11. Backup, restore and resets

This part checks encrypted backups, restores (including the refusals), the dashboard backup, and the resets that clear dashboard data, the config, or the whole install.

## Before you start

- Machines: the **upgrade box** for 11.1 to 11.5; the **fresh box** for 11.6 and 11.7. Use a terminal in the install directory.
- The steps are destructive. Run them in this order.
- Earlier steps: sections 2 to 10. 11.1 to 11.5 run in session 9 of the [Run sheet](../README.md#run-sheet). 11.6 and 11.7 run last of all on the fresh box, in session 13, after the scenarios.
- Have ready: a backup passphrase you choose in 11.1, kept somewhere safe, and the dashboard open on the laptop.
- Time: about 1 hour for 11.1 to 11.5, and about 30 minutes for 11.6 and 11.7.

## Steps

### 11.1 Encrypted backup

**What you do:**

1. Run this and choose a passphrase when it asks:

   ```bash
   ./pithead backup
   ```

2. Run `ls -l backups/`.

**What you should see:**

- A `.tar.gz.enc` file under `backups/`.
- The file is mode 600 (`-rw-------`).
- Backup restarts the stack. Stop it before each restore below; restore leaves it stopped
  until you run `./pithead up`.

**Record:** PASS, FAIL or N/A in the results sheet. Write down the backup file name.

### 11.2 Wrong passphrase

**What you do:**

1. Run `./pithead down` and check `./pithead status` shows the services stopped.
2. Run this, where `<file>` is the backup file name from 11.1. Answer `y` to the overwrite
   confirmation, then give a wrong passphrase:

   ```bash
   ./pithead restore backups/<file>
   ```

3. Run `./pithead up` and check the stack is healthy.

**What you should see:**

- The restore exits nonzero with `Wrong passphrase or corrupt archive — nothing was restored.`
- Config, rendered files and data are unchanged. A refusal saying services are still active
  does not test the passphrase: stop them and retry.

**Record:** PASS, FAIL or N/A in the results sheet.

### 11.2a A backup from a newer version is refused

**What you do:**

1. Edit `config.json` and set `config_version` to `"9.9.9"`, as in [6.10](06-settings-command-line.md#610-a-config-newer-than-the-code-warns).
2. Run `./pithead backup`.
3. Put the stamp back by hand. Run `./pithead down` and check the services are stopped.
4. Run `./pithead restore backups/<that newest file>`, answer `y` to the overwrite
   confirmation and enter the right passphrase. Use the backup you just made.
5. Run `./pithead up` and check the stack is healthy. Do not use that archive in 11.3.

**What you should see:**

Per #3109:

- The restore is refused before anything is promoted, with `This backup's configuration was written by pithead <stamp>; this machine runs <version>. Update to <stamp> or later, then restore.`
- The refusal exits nonzero. `config.json`, rendered files and data are unchanged; services
  stay stopped until item 5.

**Record:** PASS, FAIL or N/A in the results sheet.

### 11.3 Restore

**What you do:**

1. Change the energy price in the dashboard.
2. Run `./pithead down` and check the services are stopped.
3. Restore the backup from 11.1, answer `y` to the overwrite confirmation and enter the
   right passphrase:

   ```bash
   ./pithead restore backups/<file>
   ```

4. Check restore exits 0 and asks you to start the stack. Run `./pithead up`, check
   `./pithead status` is healthy, and reopen the dashboard.

**What you should see:**

- The energy price is back to its earlier value.
- The [onion](../README.md#glossary) address and the login are unchanged.
- The hashrate history is there.

**Record:** PASS, FAIL or N/A in the results sheet.

### 11.4 Dashboard backup

**What you do:**

1. In the dashboard, open **Backup** and make a backup.
2. Save both the archive and the passphrase.

**What you should see:**

- The archive downloads.
- The passphrase is shown once.

**Record:** PASS, FAIL or N/A in the results sheet.

### 11.5 Reset dashboard data

**What you do:**

1. Run this and confirm:

   ```bash
   ./pithead reset-dashboard
   ```

**What you should see:**

- The dashboard history starts from zero.
- Chains, wallets and config are untouched.
- Mining continues.

**Record:** PASS, FAIL or N/A in the results sheet.

### 11.6 Config reset

**What you do:**

1. On the **fresh box**, run:

   ```bash
   ./pithead config-reset
   ```

2. Type what it asks to confirm.
3. Run `./pithead setup`.

**What you should see:**

- You must type to confirm.
- `config.json` is removed.
- `./pithead setup` asks the setup [wizard](../README.md#glossary) questions again.
- The chains are reused, with no resync: they do not [sync](../README.md#glossary) again.

**Record:** PASS, FAIL or N/A in the results sheet.

### 11.7 Uninstall

**What you do:**

1. On the **fresh box**, as the very last step, run:

   ```bash
   ./pithead uninstall
   ```

2. Type what it asks to confirm.
3. Run `docker ps`.
4. Run `./pithead setup` again.

**What you should see:**

- You must type to confirm.
- It prints what it removed.
- It prints what it kept: `config.json`, `backups/` and the data directories.
- It prints the exact command to delete the rest.
- `docker ps` shows no Pithead containers.
- Running `./pithead setup` again brings the stack back on the kept data.

**Record:** PASS, FAIL or N/A in the results sheet.
