# Cutting and after publishing

This file covers the release cut itself, the checks after publishing, and what to watch for during any manual run.

## Before you start

- **Who.** The person cutting the release. The owner confirms the signing keys.
- **Earlier steps.** [Before the cut](before-the-cut.md).
- **Have ready.** The release issue, and [Cutting a release](../../appliance-release.md#cutting-a-release) in appliance-release.md, whose steps 3 and 4 this page uses.
- **On a debug release candidate.** `verify-image.sh` without `--test`, the release-keyring checks and "Signing must be ON" (item 1 below) refuse a debug image by design: record them N/A. They run at GA against the release artifacts. See [Testing a debug RC on the soak box](../appliance/README.md#testing-a-debug-rc-on-the-soak-box).
- **Time.** About 1 hour of checks, plus the time the build and upload take.

## Cutting

Before publication, the owner confirms that the release root certificate and signing leaf
exist, and that the root private key has an offline backup.

**What you do:**

1. Have the owner confirm that the release root certificate and signing leaf exist, and that the root private key has an offline backup.
2. Run the baked-keyring fingerprint comparison and both `rauc info --keyring` bundle checks in [appliance-release.md](../../appliance-release.md#cutting-a-release), step 3.
3. Package the verified image and bundle with step 4 there.
4. Record both published sizes, checksums, and the fingerprint and bundle verification results in the release issue.
5. Flash that `.img.xz` for the hardware battery and soak.

**Stop the cut** if either asset is at or above 2 GiB or any check fails: the first published
image establishes the trust anchor on every fielded box.

Then watch for these four items during the cut.

### 1. Signing must be ON

A release once shipped unsigned because the environment was absent and the script only warned;
the fix made it refuse, and the check still belongs on this list.

**What you do:**

1. Read the preflight output *before* answering the confirmation prompt.

**What you should see:**

- The preflight says signing is ON.

**Record:** PASS, FAIL or N/A in the results sheet.

### 2. Two-channel versions publish as a draft

Published release assets are immutable — a version was burned exactly this way.

**What you do:**

1. Cut with `--draft`.
2. Attach the `.img.xz`, `.raucb`, and both `.sha256` files alongside the DIY artifacts.
3. Publish once.

NOTE: the git tag is spent at the cut even under `--draft`, so do not start the DIY stage until
the appliance tree is believed final.

**What you should see:**

- The release stays a draft until every asset is attached, and is published once.

**Record:** PASS, FAIL or N/A in the results sheet.

### 3. Never pass `--yes` to `os-update` across a variant flip

Installing a release bundle onto a debug box removes the SSH channel driving the install. The
prompt exists for exactly that; overriding it costs the box's management channel until someone
reflashes or rolls back.

**What you do:**

1. When the bundle's variant differs from the box's, run `os-update` without `--yes`.
2. Read the prompt and answer it yourself.

**What you should see:**

- `os-update` stops at its prompt before it installs across the variant flip.

**Record:** PASS, FAIL or N/A in the results sheet.

### 4. Record the hardware battery results and the live e2e evidence

**What you do:**

1. Record the **hardware battery results** in the release issue.
2. Record the **live e2e** evidence in the release issue.

**What you should see:**

- The release issue holds both.

**Record:** PASS, FAIL or N/A in the results sheet.

## After publishing

The [Run sheet](../README.md#run-sheet) runs 12.1–12.3 ([Upgrade from the dashboard](../diy/12-upgrade-from-dashboard.md)) and this list after publishing.

**What you do:**

1. Run the post-publish smoke against the published tag, including the upgrade path from the previous release on a box that actually runs it.
2. Confirm `main` fast-forwarded to the tag — `release.sh` does this at publish. If the push was refused, run the command it printed by hand.
3. Sync `develop` → the integration branch, so the next cut does not diverge.
4. Record the per-[rig](../README.md#glossary) performance baselines you actually re-tagged (see [RELEASING.md in RigForge](https://github.com/p2pool-starter-stack/rigforge/blob/main/RELEASING.md)).
5. Reset the rigs' checkouts afterwards — a dirty checkout aborts the next tag deploy.

## Watch the operator experience, not just the asserts

A green battery says the machine works. It does not say the product is pleasant. During any
manual run, notice and file:

- Any step that goes silent for more than a minute or two without saying what it is doing or
  roughly how long it will take. A first boot that loads container images from a USB stick is
  the current worst case, and it reads as a hang.
- Any failure that leaves the console showing a stale progress message. A failed first-boot
  service once looked identical to a slow one, forever, which turned a three-minute failure into
  an hour of waiting; that one is fixed, and the shape of it is worth watching for elsewhere.
- Any message that promises a duration the machine cannot keep ("this takes a minute or two").
- Anything you had to know rather than read.

These are release-quality defects for a product whose whole promise is that a non-expert can run
it. File them with what you saw on screen; a photograph of the console is a perfectly good bug report and
has already produced two.
