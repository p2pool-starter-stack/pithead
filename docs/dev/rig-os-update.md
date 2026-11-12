# Rig OS update delivery contract

The contract for delivering an OS bundle to an appliance rig (`machine-role` is `rig`). It is written before the code (#1837); the implementation and its proof land as separate pull requests that must match it. The owner's decisions of 2026-11-10 superseded the coordinator-pull design this page first carried; §Superseded names what came out.

## Scope

- A shipped rig has no SSH, no dashboard and no control channel of Pithead's, and RigForge's git upgrade cannot apply to its baked, read-only tree. Re-flashing the media, or booting a newer stick and choosing **Keep everything** — which keeps `/data` and so the role, `rig.json` and the token (`os/installer/pithead-install:222-276`) — stays the every-layout fallback a person can do by hand; this contract is about updating without hands.
- A rig runs from its USB stick, and the stick is the supported medium: the ESP, two 4 GiB slots and `/data` on one stick, **16 GB minimum**, slot sizes unchanged. Disk-installed rigs keep working and update the same way; install-to-disk for the rig role is dropped last (#4019).
- Part 1 (the appliance flag in the feed, refusing the RigForge git upgrade, the 2.0.4 docs) belongs to #3961 and is not part of this contract.

## Design: the rig fetches its bundle itself over Tor

One path for every appliance rig, paired or standalone: on request the rig downloads the signed bundle itself through a small Tor client it starts only for that fetch and stops afterwards (`/usr/local/sbin/pithead-tor`, #4008). The coordinator never serves bundle files, and nothing new listens off-host on the rig: beyond its existing token-scoped RigForge API there is only Tor's SOCKS port, loopback-bound and alive for the duration of one fetch.

- **No timers and no automatic checks.** A rig checks for an OS update and installs one only on request through the RigForge API (#4013, rigforge#684).
- Tor is up only while the rig is fetching — the bundle, the release channel listing, any other non-pool fetch — and is stopped the moment the fetch ends. The steady-state network of a rig is its pool and, when paired, its coordinator: nothing else.
- **A rig never runs ahead of its coordinator.** The rule moved from the offer to the API call: a request made by a coordinator carries the coordinator's own version as the ceiling; a direct call defaults to latest.

## Contract

### What the coordinator serves

Nothing. It keeps no offer and serves no bundle file, no manifest and no version over the LAN, and it opens no endpoint for rigs. Its only part is on the request side: its rig-control actions (#4016) call the rig's RigForge API, passing the coordinator's own version as the ceiling.

### How the rig authenticates

The rig authenticates nothing to receive a bundle: trust is the RAUC signature against the root baked into the image, so the download channel carries no credential and none crosses the network. The request side is authenticated by RigForge's token scopes (rigforge#684): only a caller holding the rig's `ACCESS_TOKEN` can ask that rig to check or update. On the rig the token lives only on `/data`; the coordinator keeps its own copy in its worker record.

### Where the rig looks, and when

On request only, never on a schedule. A request names no URL: the rig fetches the release channel itself over Tor, and the listing is read as untrusted data: release-host allowlisted, size-capped, tag-validated, stale or replayed channels reported, all enforced by the shared fetch helper `lib/pithead/47a-os-update-channel.sh` (#4011). A failed fetch or a refused bundle changes nothing: the rig keeps mining, the reason lands in the status file, and a later request may try again.

### Where the rig verifies

- RAUC on the rig verifies the bundle signature against the root baked into the image. Nobody else's verification counts.
- The rig refuses, before installing, a bundle whose `compatible` differs from its own, whose variant differs from the running variant, whose version is older than the running version, or whose version equals the running version. `compatible` is `pithead-amd64` for every amd64 machine, so it separates architectures, not individual machines. The equal-version refusal is stricter than the coordinator's own `os-update` guard, which accepts an equal version. An unparseable version also refuses.
- The `/data` migration floor guard (`os_update_version_guard`) applies unchanged.
- Every refusal leaves the running slot untouched and the rig mining, with the reason recorded in the status file.

### Install, commit and fall back

- The rig installs with `pithead os-update -y --reboot`, which writes the idle slot and then reboots. The reboot interrupts mining for the length of the boot.
- On the new slot the rig branch of `os/overlay/pithead-boot` commits as soon as `xmrig.service` is active. Nothing checks hashing or pool reachability. This is by design, and it is the only gate a delivered bundle passes.
- If the miner never comes up, the slot stays uncommitted and the next boot returns to the previous slot, with the reason recorded; #4018 proves that return on the stick KVM leg.
- `rig.json`, the `ACCESS_TOKEN`, the role and settings live on `/data` and are unchanged by the swap.

### Status file

The rig keeps its last request time, verdict and reason in a status file on `/data`; its path and fields are fixed by #4013, which adds them to this page before it merges. The journal carries the same lines.

### Trust model

The bundle's RAUC signature is the only trust in delivery. The channel listing is untrusted and hardened (#4011); the download is anonymous over Tor; the allowlist, size cap and tag validation bound what the rig fetches, and authenticate nothing. A rig that trusts only the baked keyring depends on its validity across time — release signing key rotation, certificate expiry and clock handling are #4012.

### Limits

- A bundle carries the rootfs only. It never changes `grub.cfg` on the ESP, so a delivered update does not add or reorder boot menu entries. The menu title shows the slot version from the boot environment, which `os-update` updates.
- The bundle has no role in it (`compatible=pithead-amd64`, one rootfs). Every role installs the same bundle.

## Superseded on 2026-11-10

The first draft of this contract had the coordinator retain a copy of its own installed bundle in an offer directory and serve it over the LAN to rigs that proved the `ACCESS_TOKEN` by HMAC-nonce challenge, the rig checking once a day on a random-offset timer gated on `MEDIA=internal`, and delivery limited to disk-installed rigs. All of that is gone: the retained offer, the HMAC endpoint, the daily timer and the `MEDIA` gate are removed, delivery is not disk-only, and a rig fetches over Tor instead. The verification, install, self-commit, fallback and status-file rules survived unchanged.

## Follow-up pull requests

Each is separate; `#1837` closes with the last.

| Order | Change | Proof |
|---|---|---|
| 1 | #4008: the on-demand Tor client in the image | `tier4-kvm` on its own head |
| 2 | #4011: the hardened untrusted update channel | `tier4-kvm` and selftests |
| 3 | #4013: the rig-side updater behind the RigForge API call | `tier4-kvm` on its own head |
| 4 | #4016: the coordinator's Upgrade rig and Update all | `tier4-e2e` |
| 5 | #4018: the stick KVM legs — update over Tor, fallback, revoke, internal disk untouched | `tier4-kvm`, one bounded run, no soak |
