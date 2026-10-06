# Running the DIY boxes as virtual machines

How to build the fresh box and the upgrade box as virtual machines for the DIY sections, and
which checks a virtual machine cannot prove.

## Before you start

- Which machine: a Linux host with KVM (libvirt or similar).
- Earlier steps: none. Build both boxes before session 2 of the
  [Run sheet](../README.md#run-sheet), and start the upgrade box a few days ahead (see
  [Sync time](#sync-time)).
- Have ready: the Ubuntu Server 24.04 LTS installer, and the previous release for the upgrade
  box. The rest of the equipment is in [What you need](../what-you-need.md).
- Only the fresh box and the upgrade box can be virtual machines. The appliance, the restore PC
  and the rigs cannot: [sections 13–15](../appliance/README.md) need real hardware.
- Rough time: about an hour of hands-on work per box, then the chain
  [sync](../README.md#glossary), which takes days over [Tor](../README.md#glossary).

On the project's own bench fleet, bench-ci's sandbox sessions have merged
([p2pool-starter-stack/bench-ci#1433](https://github.com/p2pool-starter-stack/bench-ci/issues/1433)).
Once a bench is configured for them, its status page starts and ends a full or small VM with this
spec. Until then, and anywhere else, build one with any KVM tool to the same spec.

## The VM settings

| Setting | Value | Why |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS, nothing of Pithead on it | The fresh-box baseline in [1.1](01-fresh-install.md) |
| CPU | Host passthrough (libvirt `host-passthrough`), 6 or more vCPUs | The guest must see AVX2 and AES; the RandomX miner and the build need them |
| Memory | 16 GB for a box that runs both chains | The documented minimum. Less tests an undersized box, not the release |
| Disk | 700 GB, thin-provisioned | 600 GB for both chains, plus headroom |
| Network | Its own address on your LAN (bridged or macvtap) | The laptop, the miners and the phone must reach its dashboard and [stratum](../README.md#glossary) port; a NAT network hides it |

## Build the boxes

**What you do:**

1. Create a virtual machine with the settings in the table above.
2. Install Ubuntu Server 24.04 LTS on it, with nothing of Pithead.
3. Right after the OS install, take a snapshot named *clean*.
4. Upgrade box only: install the previous release and let it sync. To save days, set
   `clearnet_initial_sync` to `true` under both `monero` and `tari` (see [Sync time](#sync-time)).
5. Upgrade box only: once the previous release has synced, take a second snapshot named
   *previous release synced*.

**What you should see:**

- Each box has its own address on your LAN, not an address behind NAT.
- The fresh box has a *clean* snapshot; the upgrade box also has a *previous release synced*
  snapshot.

**Record:** nothing to write down; this is setup. Note in the results sheet that the run used
virtual machines.

## Snapshots

- Take one right after the OS install (*clean*) and one once the previous release has synced
  (*previous release synced*).
- [Section 1](01-fresh-install.md) starts from *clean*, and [section 2](02-upgrade.md) from
  *previous release synced*.
- Reverting repeats a route without reinstalling.

## Sync time

- A box syncing both chains from zero over Tor takes days.
- For the upgrade box, install the previous release with `clearnet_initial_sync` set to `true`
  under both `monero` and `tari`. That exposes the box's IP while it syncs, which is acceptable on
  a sandbox. Otherwise, start it a few days ahead.
- 1.1–1.11 do not need the chains synced. 1.12 needs Monero synced while Tari is still syncing,
  and 1.13 needs both synced.

## Two boxes at once

Session 9 uses both boxes.

- The fresh box runs its own chains in 1.12, 1.13, 10.1, 10.2 and 10.7.
- In 10.3, 10.3a, 10.4 and 10.6, the upgrade box serves its node to a second machine that runs no
  chain of its own.

**A host with room for two full boxes** (32 GB of memory for the guests): keep both running and
follow the [Run sheet](../README.md#run-sheet) as written. The fresh box is the second machine.

**A host with room for one full box (16 GB) plus a small VM (about 6 GB):**

1. Fresh box: session 2 (1.1–1.11). Set it aside.
2. Upgrade box: install the previous release, let it sync, and take the *previous release
   synced* snapshot. Then run sessions 3–8. Set it aside.
3. Fresh box: start it again and watch its sync on the dashboard a few times a day. If Monero
   finishes its first sync while Tari is still syncing, run 1.12 in that window. Once both chains
   are synced, run 1.13, 10.1, 10.2 and 10.7. Set it aside.
   - If Tari finishes first, the window never happened: record 1.12 as SKIP and say so.
   - If the window passed before you saw it, 1.12 is not covered yet; do not record SKIP. Note it
     as missed and carry on. After step 5, revert the fresh box to its *clean* snapshot, run
     1.1–1.11 again, and check the dashboard more often during the sync until 1.12 runs in its
     window.
4. Upgrade box: start it again, and start a small VM as the second machine, configured for a
   remote node. Run 10.3, 10.3a, 10.4 and 10.6, then 10.5 and 11.1–11.5. Remove the small VM.
5. Fresh box: start it again for session 13 (S1–S8 where they use it, then 11.6 and 11.7 last).

To set a box aside, shut it down cleanly (`sudo poweroff` inside it), or save its state to disk
with libvirt's managed save. A paused VM keeps its memory, so pausing frees nothing for the other
box. When a shut-down box starts again, Pithead starts its services, and the chains carry on
syncing from where they stopped.

## What a VM cannot prove

- HugePages and MSR tuning for the built-in miner, USB sticks, power cuts, physical disks and
  real network cards.
- Walk those steps on hardware.

**Record:** N/A for those steps on a VM run, never PASS.

## Host load

- Give the VM its own cores where you can.
- A busy host slows the guest enough to turn timing-sensitive steps (sync waits, alert
  debounces) into false failures.
