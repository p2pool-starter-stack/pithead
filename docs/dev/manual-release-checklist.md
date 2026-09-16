# The manual release checklist

Everything a release needs that no harness can do for you, and the traps that have actually
bitten. The automated gates are described in [releasing.md](releasing.md) (DIY channel) and
[appliance-release.md](appliance-release.md) (appliance channel); this page is the human half,
and it exists because a checklist nobody wrote down is a checklist nobody runs.

Each item says **why it cannot be automated**. That matters: anything on this list that becomes
automatable should move off it, and anything that keeps biting should get a harness leg.

---

## Before the cut

### Confirm what the harness cannot see

The KVM battery boots a VM on a virtual NIC, one virtual disk, and no firmware. It can stage an
unrouted documentation-range global IPv6 address, but it is structurally blind to the following,
all of which have produced real defects:

| Check | Why a VM cannot show it |
|---|---|
| Secure Boot, firmware power-on behaviour, real disk topology | No firmware, one virtual disk. |
| Thermals, CPU governor, the hardware watchdog actually resetting a wedged board | A VM has no watchdog device and no heat. |
| First-boot on real media — wall-clock, and what a power cut leaves behind | Writing container storage to a USB stick is nothing like a virtual disk, and the operator experience lives in that gap. An interrupted write to a stick left a store that was present, digest-matched and unrunnable, and it bricked install-from-stick on every later boot (#1029). Fault D covers the interrupted first-boot image-load and repair path on a virtual disk; real-media wear and firmware behaviour remain hardware-only. |

### Reserve the hardware

Bench resources are shared with other sessions and with RigForge's own gates. Reserve before
touching anything, free when done — see the reservation protocol in
[release-server.md](release-server.md). The loaner rigs carry their own contract at `~/README.md`
on each box: back up the config, repoint, and **restore + restart when the job frees it**.

That protocol covers the **rigs**. It does not cover the appliance under test, which
[#1022](https://github.com/p2pool-starter-stack/pithead/issues/1022) records as having no lock, no
holder marker and no contract file of its own — so nothing stops two sessions working on it at
once, and the battery below reflashes and factory-resets the box. A collision costs whoever else
is holding it both their run and the chain on that disk. Until #1022 lands a mechanism, reserving
the appliance is an agreement between sessions and nothing enforces it: say in your handoff that
you are holding it, and say when you let go.

The appliance cannot copy the rig protocol, and #1022 names the reason: a lock stored *on*
the appliance is destroyed by the very tests that take it. Its reservation has to live on a
coordinator that the reflash does not touch.

### Know which image you are holding

A **debug** image (sshd on, keys baked) is bench equipment. A **release** image is shell-less
with no keys. `verify-image.sh` without `--test` refuses a debug build, and that refusal is the
last thing standing between a development convenience and a published one. Never publish a debug
image; never hand one to a user.

---

## The manual hardware battery (M1–M10)

Defined in [appliance-release.md](appliance-release.md). Run its remaining hardware-only checks on a physical box and record the
results in the release issue. The KVM battery covers the scriptable parts noted below; the physical
checks remain hands-on until #1022 can collect the scripted and attested results together.

Needs hands, every time:

- **M1 — flash and boot** from a real stick with Secure Boot disabled in firmware.

M4's mechanics (the wrong-disk guard) now have a KVM analog — see
[appliance-release.md](appliance-release.md) — so only the real-hardware disk-controller
cases still need a physical second disk.

The power-cut items are the ones that justify the whole appliance design (A/B slots, the
health-gated commit, the migration hold). Two are now in the KVM battery — a virtual disk cannot
show USB-stick media damage or the firmware's Restore-on-AC-Power-Loss setting, so the box coming
back **by itself** after the plug is pulled still needs hands on real hardware:

- **M8 — power cut during the update's write phase.** *Covered by: `fault` phase Fault A
  (destroy mid-write, `tests/os/phases/fault.sh`) — pull the plug at the wall on real hardware to
  confirm Restore on AC Power Loss, not the write itself.*
- **M10 — power cut during normal mining.** *Covered by: `provision` phase's power-cut leg
  (M10, #2067, `tests/os/phases/provision-power-cut.sh`) — same caveat.*

### Install-path cases worth walking deliberately

- A **fresh** disk.
- A disk that **already holds an installation** — choose *keep* and confirm the chain survives
  (this is M5, and it is where the corrupt-container-store blocker was found: a partially written
  image store left every `podman run` failing, so the wizard never served).
- Reaching the wizard **by mDNS name** and **by IP**, since the appliance serves both.
- Confirming once that the dashboard refuses the real box's ISP-assigned IPv6 address. The
  provision battery proves the listener boundary with an unrouted RFC 3849 address; this check
  confirms that the physical network presents the same address shape.
- Configuring **by paste** for both addresses (M6, which now needs a yes to merge-mining first —
  a new machine is asked for the Monero address only): a wallet address typed by hand is a support
  ticket waiting to happen.

---

## The rig-role manual battery (M11–M13)

Defined in [appliance-release.md](appliance-release.md). Required for any release that touches
the rig role. The `rig` KVM phase only proves the wizard's
rig card, role select, a submit toward a faked pool listener, volatile journald, a plain reboot,
a power cut, and the A/B update leg — so these three stay hands-on until #1886's first gap
converts what it can and names a bench e2e for the rest. Each row below names the check that
replaces it once that lands. M14 (run-from-USB) no longer needs a hand-run: the `rigmedia` KVM
phase (`tests/os/phases/rigmedia.sh`, #2069) covers it — see the row below for what it proves and
what it still leaves out.

- **M11 — rig install and mine.** Flash the same stick; boot a rig-class loaner (never a
  production-only rig); choose RigForge; point it at a real coordinator. Expected: the rig card
  shows worker + pool with no login, the coordinator's dashboard shows the worker with accepted
  shares within minutes, `doctor` on the rig reports MSR applied and hugepages reserved, and
  hashrate sits within the box's recorded baseline band. *Replaced by: the accepted-share and
  `doctor` MSR/hugepages checks #1886's gap 1 still has to add — the KVM phase fakes the pool
  listener and never accepts a share, and asserts nothing about MSR or hugepages.*
- **M12 — rig from the coordinator's dashboard.** From the coordinator's Worker Inspect, adopt
  the rig, apply one writable change (for example the donation level), and watch it reach
  `applied`; confirm no pool credential was touched. *Replaced by: a dashboard-driven adopt/config
  push check, not yet written — a rig serves no dashboard of its own, so nothing in the KVM `rig`
  phase exercises this today.*
- **M13 — rig power loss and rig update.** Cut power at the wall with the rig mining; it must
  return mining unaided (Restore on AC power loss). Then install the release bundle on the rig and
  confirm it comes back mining on the new slot and self-commits. *Covered by: the `rig` phase's
  power-cut leg (#2067, `tests/os/phases/rig.sh`) proves the return-mining-unaided fact off a real
  `virsh destroy`, and the phase's existing update leg proves the install/self-commit half. What
  stays manual is Restore on AC Power Loss itself — a firmware setting a virtual disk cannot show.*
- **M14 — run-from-USB rig. AUTOMATED (#2069).** Boot the stick, choose RigForge, do **not**
  install to disk. Expected: it mines from the stick; a reboot returns it mining; reaching the
  wizard again needs the bootloader path (#1318). *Replaced by: the `rigmedia` KVM phase
  (`tests/os/phases/rigmedia.sh`), which boots the image as removable media beside a blank
  internal disk, answers RigForge with no install offered, and asserts the stick-run rig mines
  the baked binary with no containers, volatile journald, an unaided reboot returns it mining,
  and the blank disk stays byte-for-byte untouched. Still manual: reaching the wizard again via
  the bootloader path (#1318) on a stick-run rig, and stick wear / wall-clock on real USB media.*

---

## Cutting

1. **Signing must be ON.** Confirm the preflight says so *before* answering the confirmation
   prompt. A release once shipped unsigned because the environment was absent and the script
   only warned; the fix made it refuse, and the check still belongs on this list.
2. **Two-channel versions publish as a draft.** Published release assets are immutable — a
   version was burned exactly this way. Cut with `--draft`, attach both channels' artifacts,
   publish once. Note the git tag is spent at the cut even under `--draft`, so do not start the
   DIY stage until the appliance tree is believed final.
3. **Never pass `--yes` to `os-update` across a variant flip.** Installing a release bundle onto
   a debug box removes the SSH channel driving the install. The prompt exists for exactly that;
   overriding it costs the box's management channel until someone reflashes or rolls back.
4. Record the **hardware battery results** and the **live e2e** evidence in the release issue.

## After publishing

- Post-publish smoke against the published tag, including the upgrade path from the previous
  release on a box that actually runs it.
- Confirm `main` fast-forwarded to the tag — `release.sh` does this at publish. If the push was
  refused, run the command it printed by hand.
- Sync `develop` → the integration branch, so the next cut does not diverge.
- Record the per-rig performance baselines you actually re-tagged (see
  [RELEASING.md in RigForge](https://github.com/p2pool-starter-stack/rigforge/blob/main/RELEASING.md)),
  and reset the rigs' checkouts afterwards — a dirty checkout aborts the next tag deploy.

---

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
it. File them with what you saw on screen; a photograph of the console is a perfectly good bug
report and has already produced two.
