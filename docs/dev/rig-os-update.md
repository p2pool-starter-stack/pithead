# Rig OS update delivery contract

The contract for delivering an OS bundle to an appliance rig (`machine-role` is `rig`). It is written before the code (#1837, Part 2); the implementation and its proof land as separate pull requests that must match it.

## Scope

- A shipped rig has no SSH, no dashboard and no control channel of Pithead's, and RigForge's git upgrade cannot apply to its baked, read-only tree. Today a rig moves to a newer OS only by re-flashing its media or by booting a newer stick and choosing **Keep everything**.
- Delivery covers **disk-installed rigs only**. The KVM rig phase proves the A/B install, the role and settings surviving the swap, and the self-commit on that layout. A rig that runs from its USB stick re-flashes until manual row M14 (#1829) measures the stick layout (ESP, two 4 GiB slots and `/data` on the stick). Docs claim remote update only for measured layouts.
- Part 1 (the appliance flag in the feed, refusing the RigForge git upgrade, the docs paragraph) belongs to #3961 and is not part of this contract.

## Design: the rig pulls from its coordinator

Rigs dial the coordinator. Nothing new listens on a rig and nothing is fetched over clearnet: the coordinator already fetches releases over Tor (`os-check` and `os-download`, `lib/pithead/48-os-update-verbs.sh`), and the rig reads the result over the LAN.

A rig never runs ahead of its coordinator. The operator consents to an update on the coordinator, by running `os-check`, `os-download` and `os-verify` there. A rig installs only what the coordinator holds as verified.

## Contract

### What the coordinator serves

- Only the bundle recorded in the coordinator's OS-update staging directory by a completed `os-verify` (`target.json` names its tag). If no bundle is verified, the coordinator answers "none available" and serves nothing.
- Over the LAN only. The endpoint is not published on Tor and not reachable from outside the coordinator's own network.
- The coordinator serves the `.raucb` file and its version and `compatible` string as they stand. It signs nothing and publishes no manifest.

### How the rig authenticates

- The rig presents the `access_token` it already holds in `rig.json` (the #1836 RigForge `ACCESS_TOKEN`). There is no new credential and no new storage format.
- The coordinator compares it in constant time against the token it stores for that rig. A missing or wrong token gets an empty answer: no bundle, no version, no hint of which part failed.
- Neither side logs the token, and the coordinator's audit log records the rig and the verdict only.

### Where the rig looks, and when

- The rig finds the coordinator through the pool host in `rig.json`.
- It checks once a day, at a random offset within the day, so rigs behind one coordinator do not fetch together.
- When the coordinator is unreachable, answers "none available", or rejects the token, the rig keeps mining, records the reason, and tries again next cycle. A failed check never changes the running slot or stops the miner.

### Where the rig verifies

- RAUC on the rig verifies the bundle signature against the root baked into the image. The coordinator's verification does not replace it.
- The rig refuses, before installing, a bundle whose `compatible` differs from its own, whose version is older than the running version, or whose version equals the running version. The equal-version refusal is stricter than the coordinator's own `os-update` guard, which accepts an equal version. An unparseable version also refuses.
- The `/data` migration floor guard (`os_update_version_guard`) applies unchanged.
- Every refusal leaves the running slot untouched and the rig mining, with the reason recorded.

### Install, commit and fall back

- The rig installs with `pithead os-update` into its idle slot, then reboots.
- On the new slot the rig branch of `os/overlay/pithead-boot` commits as soon as `xmrig.service` is active. Nothing checks hashing or pool reachability. This is by design, and it is the only gate a delivered bundle passes.
- If the miner never comes up, the slot stays uncommitted, the next boot returns to the previous slot, and the reason is recorded.
- `rig.json`, the `ACCESS_TOKEN`, the role and settings live on `/data` and are unchanged by the swap.

### Limits

- A bundle carries the rootfs only. It never changes `grub.cfg` on the ESP, so a delivered update does not change an installed rig's boot menu.
- The bundle has no role in it (`compatible=pithead-amd64`, one rootfs). Every role installs the same bundle.

## Follow-up pull requests

Each is separate, in this order. `#1837` closes with the last.

| Order | Change | Proof |
|---|---|---|
| 1 | Coordinator endpoint: serves the verified bundle behind the rig token | `tier4-e2e` on its own head |
| 2 | Rig timer and fetch under `os/` | `tier4-kvm` on its own head |
| 3 | Rejection tests: unsigned bundle, wrong `compatible`, older and equal version, missing or wrong token | `tests/os` selftests and a `tier4-kvm` leg |
| 4 | KVM proof: rig on an older bundle, coordinator holding a newer verified one; install, reboot, commit, mine on the new slot; role, `rig.json`, `ACCESS_TOKEN` and settings unchanged; the version survives a further reboot; an uncommitted slot falls back | `tier4-kvm`, one bounded run, no soak |
