# Rig OS update delivery contract

The contract for delivering an OS bundle to an appliance rig (`machine-role` is `rig`). It is written before the code (#1837, Part 2); the implementation and its proof land as separate pull requests that must match it.

## Scope

- A shipped rig has no SSH, no dashboard and no control channel of Pithead's, and RigForge's git upgrade cannot apply to its baked, read-only tree. Today a rig moves to a newer OS only by re-flashing its media or by booting a newer stick and choosing **Keep everything**.
- Delivery covers **disk-installed rigs only**. The KVM rig phase proves the A/B install, the role and settings surviving the swap, and the self-commit on that layout. A rig that runs from its USB stick re-flashes until a delivery test passes on a measured stick layout (ESP, two 4 GiB slots and `/data` on the stick; the `rigmedia` phase automates row M14, #2069). Docs claim remote update only for measured layouts. The rig timer enforces this: it does nothing when `MEDIA=usb` in the boot environment (`grub-editenv`, written at boot by `pithead-boot-version record-booted`). No minimum stick size is established, and the claim stays disk-only until a delivery test measures one.
- Part 1 (the appliance flag in the feed, refusing the RigForge git upgrade, the docs paragraph) belongs to #3961 and is not part of this contract.

## Design: the rig pulls from its coordinator

Rigs dial the coordinator. Nothing new listens on a rig and nothing is fetched over clearnet: the coordinator already fetches releases over Tor (`os-check` and `os-download`, `lib/pithead/48-os-update-verbs.sh`), and the rig reads the result over the LAN.

A rig never runs ahead of its coordinator. The operator consents to an update on the coordinator, by running `os-check`, `os-download` and `os-verify` there. A rig installs only what the coordinator holds as verified.

## Contract

### What the coordinator serves

- Only the staged bundle that `target.json` names, and only while the recorded OS-update state (`results/os-update-state.json`) is `verified` for that same tag. A bundle that is downloaded but not verified, or whose tag differs from the state, is not served: the coordinator answers "none available".
- Over the LAN only. The endpoint is not published on Tor and not reachable from outside the coordinator's own network.
- The coordinator serves the `.raucb` file and its version as they stand. It signs nothing and publishes no manifest.
- The endpoint's scheme, port and path are fixed by the coordinator-endpoint pull request, which adds them to this page before it merges.

### How the rig authenticates

- The rig presents the `access_token` it already holds in `rig.json` (the #1836 control token, which Pithead mints and renders into RigForge's `ACCESS_TOKEN`). There is no new credential and no new storage format.
- The coordinator compares it in constant time against the token it holds for that rig in its worker record, the one it already uses to call the rig. A missing or wrong token gets an empty answer: no bundle, no version, no hint of which part failed.
- Neither side logs the token, and the coordinator's audit log records the rig and the verdict only.

### Where the rig looks, and when

- The rig finds the coordinator through the pool host in `rig.json`. If that host is an onion address or does not resolve to a LAN address, the rig does not check.
- It checks once a day, at a random offset within the day, so rigs behind one coordinator do not fetch together.
- When the coordinator is unreachable, answers "none available", or rejects the token, the rig keeps mining, records the reason in its status file, and tries again next cycle. A failed check never changes the running slot or stops the miner.

### Where the rig verifies

- RAUC on the rig verifies the bundle signature against the root baked into the image. The coordinator's verification does not replace it.
- The rig refuses, before installing, a bundle whose `compatible` differs from its own, whose variant differs from the running variant, whose version is older than the running version, or whose version equals the running version. `compatible` is `pithead-amd64` for every amd64 machine, so it separates architectures, not individual machines. The equal-version refusal is stricter than the coordinator's own `os-update` guard, which accepts an equal version. An unparseable version also refuses.
- The `/data` migration floor guard (`os_update_version_guard`) applies unchanged.
- Every refusal leaves the running slot untouched and the rig mining, with the reason recorded in the status file.

### Install, commit and fall back

- The rig installs with `pithead os-update -y --reboot`, which writes the idle slot and then reboots. The reboot interrupts mining for the length of the boot; the timer runs only after the rig has been up long enough to have committed its current slot.
- On the new slot the rig branch of `os/overlay/pithead-boot` commits as soon as `xmrig.service` is active. Nothing checks hashing or pool reachability. This is by design, and it is the only gate a delivered bundle passes.
- If the miner never comes up, the slot stays uncommitted and the next boot returns to the previous slot. The rig branch of `pithead-boot` writes no record today, so the timer's follow-up PR adds one: on the next run the rig compares the booted version with the version it installed and writes the mismatch to the status file.
- `rig.json`, the `ACCESS_TOKEN`, the role and settings live on `/data` and are unchanged by the swap.

### Status file

The rig keeps its last check time, verdict and reason in a status file on `/data`; its path and fields are fixed by the rig-timer pull request, which adds them to this page before it merges. The journal carries the same lines.

### Limits

- A bundle carries the rootfs only. It never changes `grub.cfg` on the ESP, so a delivered update does not add or reorder boot menu entries. The menu title shows the slot version from the boot environment, which `os-update` updates.
- The bundle has no role in it (`compatible=pithead-amd64`, one rootfs). Every role installs the same bundle.

## Follow-up pull requests

Each is separate, in this order. `#1837` closes with the last.

| Order | Change | Proof |
|---|---|---|
| 1 | Coordinator endpoint: serves the verified bundle behind the rig token | `tier4-e2e` on its own head |
| 2 | Rig timer and fetch under `os/` | `tier4-kvm` on its own head |
| 3 | Rejection tests: unsigned bundle, wrong `compatible`, older and equal version, missing or wrong token | `tests/os` selftests and a `tier4-kvm` leg |
| 4 | KVM proof: rig on an older bundle, coordinator holding a newer verified one; install, reboot, commit, mine on the new slot; role, `rig.json`, `ACCESS_TOKEN` and settings unchanged; the version survives a further reboot; an uncommitted slot falls back | `tier4-kvm`, one bounded run, no soak |
