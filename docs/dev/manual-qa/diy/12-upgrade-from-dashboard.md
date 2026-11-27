# 12. Upgrade from the dashboard

This part checks the dashboard's new-release badge and one-click upgrade on a DIY box, and the OS update control on an appliance.

## Before you start

- This part needs the published release, so run it during [After publishing](../release/cutting-and-after.md#after-publishing), not before the cut.
- Machines:
  - For 12.1 and 12.2: a DIY box that still runs the previous release with `dashboard.control.enabled: true`. The upgrade box no longer does after [2.2](02-upgrade.md). After [11.7](11-backup-restore-resets.md#117-uninstall), install the previous release's bundle on the fresh box and use that.
  - For 12.3: an appliance that runs the previous release. Never the soak box while it carries a soak.
- Have ready: the laptop, with the dashboard of each machine open and signed in. In the steps below, `vX.Y.Z` is the version just published.
- Time: about 1 hour for 12.1 and 12.2, and about 1 hour for 12.3.

## Steps

### 12.1 Badge

**What you do:**

1. On the DIY box's dashboard, look at the header.

**What you should see:**

- The header shows `New release vX.Y.Z available`, linking to the release.
- An **Upgrade to vX.Y.Z** button.

**Record:** PASS, FAIL or N/A in the results sheet.

### 12.2 Upgrade

**What you do:**

1. Click **Upgrade to vX.Y.Z**.
2. Type `UPGRADE`.

**What you should see:**

- The page disconnects briefly, then comes back on the new version.
- The badge clears.
- Config, wallets and chains are unchanged.

**Record:** PASS, FAIL or N/A in the results sheet.

### 12.3 Appliance OS update

Skip this step, recording SKIP, when the previous release shipped no appliance image, as for the first appliance release. Never run it on the soak box while it carries a soak.

**What you do:**

1. On the appliance's dashboard, open the header's **OS updates** control.
2. Click Check.
3. Click Download.
4. Click Verify.
5. Click Install.
6. Click Reboot, and type `REBOOT`.
7. Watch the boot menu as the appliance restarts, then the dashboard page.

**What you should see:**

- Check offers the new release.
- Mining keeps running until the reboot. Install arms the spare [slot](../README.md#glossary), though, so any reboot boots the update (#3100).
- The **Reboot** button expires 24 hours after Install.
- The page reconnects after the reboot.
- A banner says the appliance updated.
- The boot menu shows the new version as **current** and the old one as **previous**.

**Record:** PASS, FAIL, N/A or SKIP (as above) in the results sheet.
