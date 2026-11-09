# Rig OS update delivery contract

The contract for delivering an OS bundle to an appliance rig (`machine-role` is `rig`). It is written before the code (#1837, Part 2); the implementation and its proof land as separate pull requests that must match it.

## Scope

- A shipped rig has no SSH, no dashboard and no control channel of Pithead's, and RigForge's git upgrade cannot apply to its baked, read-only tree. Today a rig moves to a newer OS only by re-flashing its media or by booting a newer stick and choosing **Keep everything**, which keeps `/data` and so the role, `rig.json` and the token (`os/installer/pithead-install:222-276`). No test proves that route for a rig yet; #3961 asks for it.
- Delivery covers **disk-installed rigs only**. The KVM rig phase proves the A/B install, the role and settings surviving the swap, and the self-commit on that layout. A rig that runs from its USB stick re-flashes until a delivery test passes on a measured stick layout (ESP, two 4 GiB slots and `/data` on the stick; the `rigmedia` phase automates row M14, #2069). Docs claim remote update only for measured layouts. The rig timer enforces this and fails closed: it proceeds only when `MEDIA=internal` in the boot environment (`grub-editenv`, written at boot by `pithead-boot-version record-booted`). An unset or unreadable `MEDIA` (`record_media` can fail) counts as not internal. No minimum stick size is established, and the claim stays disk-only until a delivery test measures one.
- Part 1 (the appliance flag in the feed, refusing the RigForge git upgrade, the docs paragraph) belongs to #3961 and is not part of this contract.

## Design: the rig pulls from its coordinator

Rigs dial the coordinator. Nothing new listens on a rig and nothing is fetched over clearnet: the coordinator already fetches releases over Tor (`os-check` and `os-download`, `lib/pithead/48-os-update-verbs.sh`), and the rig reads the result over the LAN.

A rig never runs ahead of its coordinator. The operator consents to an update on the coordinator, by running `os-check`, `os-download`, `os-verify` and `os-install` there. The coordinator offers a rig only the version it has itself installed and committed, so a rig is never newer than the machine it reports to.

## Contract

### What the coordinator serves

- Only the **rig offer**: a retained copy of the bundle the coordinator itself installed, keyed to its tag. `os-install` moves the verified bundle into the offer directory (a sibling of the staging directory under `/data`) instead of deleting it at `lib/pithead/48-os-update-verbs.sh:323`, replacing any older offer. This is needed because `os-install` removes the staged bundle and `target.json`, and the coordinator's committing boot returns the state to `idle` (`os/overlay/pithead-boot`), so a gate on the transient `verified` step would be open only between `os-verify` and `os-install`, and a rig checking once a day would usually find nothing.
- The offer is served only while the coordinator's running version equals the offer's tag. After a rollback, a failed commit or a later downgrade the versions differ and the coordinator answers "none available". A bundle that was downloaded but never installed is never served.
- The offer counts against `/data` headroom: the `os-download` space check includes the retained offer, and a factory reset removes it with the rest of `/data`.
- Over the LAN only. The endpoint is not published on Tor and not reachable from outside the coordinator's own network.
- The coordinator serves the `.raucb` file and its version as they stand. It signs nothing and publishes no manifest.
- The endpoint's scheme, port and path are fixed by the coordinator-endpoint pull request, which adds them to this page before it merges.

### How the rig authenticates

- The rig proves it holds the `access_token` in `rig.json` (the #1836 control token, which Pithead mints and renders into RigForge's `ACCESS_TOKEN`). There is no new credential and no new storage format.
- The token never crosses the LAN. The coordinator sends a random nonce and the rig answers with HMAC-SHA256 of it keyed by the token, so a host on the LAN that spoofs the pool-host name learns nothing reusable. This refines the ruling's "constant-time compare": the compare is the same, on the HMAC instead of the token. The endpoint pull request fixes the framing.
- The rig sends no identity beyond the proof. The coordinator computes the expected HMAC for every rig token in its worker records and compares each in constant time without stopping at a match, so the matching record identifies the rig. A missing, wrong or unknown proof gets an empty answer: no bundle, no version, no hint of which part failed.
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
| 1 | Coordinator endpoint, plus the `os-install` change that retains the rig offer and the space check: serves the offer behind the rig proof | `tier4-e2e` on its own head |
| 2 | Rig timer and fetch under `os/` | `tier4-kvm` on its own head |
| 3 | Rejection tests: unsigned bundle, wrong `compatible`, older and equal version, missing or wrong token | `tests/os` selftests and a `tier4-kvm` leg |
| 4 | KVM proof: rig on an older bundle, coordinator holding a newer verified one; install, reboot, commit, mine on the new slot; role, `rig.json`, `ACCESS_TOKEN` and settings unchanged; the version survives a further reboot; an uncommitted slot falls back | `tier4-kvm`, one bounded run, no soak |
