# Appliance image harness

Tier-4 tests for the `pithead-os` appliance image (#77 phase 2): the properties only real
firmware and a real A/B updater can prove. The compose/CLI stack is covered by the other
tiers ([`docs/dev/testing-strategy.md`](../../docs/dev/testing-strategy.md)); this harness
covers what the flashed image adds — EFI boot, the first-boot wizard window, install-to-disk,
the rig role, and the update → commit → rollback cycle that is the phase-2 exit criterion.
The stable `run.sh` entry point loads shared helpers from `lib/` and phase implementations from
`phases/`; `selftest-run-modules.sh` checks the complete load order without starting a VM.

It needs a Linux host with KVM, libvirt and qemu, and root (the bench, not CI):

```bash
sudo cp /root/.ssh/pithead-os-test.pub /tmp/pithead-os-test.pub
# Publish the five first-party images under the tag the appliance will ask for, then point the
# build at that registry. PITHEAD_REGISTRY_CA is needed only when the registry is TLS.
PITHEAD_REGISTRY=<host:port> PITHEAD_REGISTRY_CA=<ca.crt> \
    os/build-image.sh --ssh /tmp/pithead-os-test.pub # battery runs as root and uses root's key
os/rauc/mkimage.sh --dev                      # bootable image -> os/rauc/build/system.img
sudo env PITHEAD_REGISTRY=<host:port> PITHEAD_REGISTRY_CA=<ca.crt> \
    tests/os/run.sh --image os/rauc/build/system.img
```

`sudo` resets the environment (`env_reset`), so the override has to be passed THROUGH it — the phases rebuild the image themselves via `_build_image`, so an exported variable that sudo drops produces exactly the zero-container appliance this avoids.

`PITHEAD_REGISTRY` is not optional on a tree whose `VERSION` is unreleased, and that is the usual
case here. Only the wizard's dashboard image is baked into the appliance, so at first boot every
other service is a PULL of `pithead-<service>:v$(cat VERSION)` — tags that exist nowhere public
until that version ships. Without the override the appliance provisions, publishes its dashboard
credentials, and then runs ZERO containers; the legs that wait for a stack each take up to 25
minutes to report it, and nothing in the battery's own output says the image was built wrong
(#2043). `build-image.sh` now resolves those five refs up front and refuses a bench build that
cannot pull them, so this is a fast error rather than a slow mystery — and
`tests/os/zero-container-evidence.sh` dumps the guest's image lists at every such leg, where
`comm -23 want have` separates a missing ref from a refusal with every ref present.

`tests/os/bundle-build-evidence.sh` is the same idea for the other row five legs report and none of
them read: a bundle build failed, and the assertion names `/tmp/os-fault-bundle.log` instead of
printing it. The build runs on the host, so the evidence outlives the guest — which is exactly why
the omission was expensive (#2060). A missing log, an empty one and a failing build each get their
own sentence, because "nothing to show" and "nothing went wrong" are different facts. It is also the
first thing to put build-log lines on the battery's stdout, so `PITHEAD_REGISTRY` and
`PITHEAD_REGISTRY_CA` are masked out of the tail from the environment — the failing image ref
survives, because which ref failed is the diagnostic and the bench host is not.

Keep the registry host, port and CA path out of this repo: they are bench topology. The working
values live in the private bench notes.

Do not override `HOME` under `sudo`: the runner intentionally reads
`/root/.ssh/pithead-os-test`. An image built with the invoking user's key looks like an SSH
timeout to the root-run battery even when the guest is healthy.

Every guest boot is preceded by a host pre-flight (`tests/os/kvm-preflight.sh`): under 20 GiB of
`MemAvailable` the battery refuses to boot the 16 GiB guest rather than risk hanging the host that
runs it (`PITHEAD_KVM_MIN_AVAIL_MB` sets the bar; the reading is printed at every boot either way).

The harness builds its own update bundles from the same tarball (`os/rauc/mkbundle.sh --dev`),
signed with a throwaway development key. A release build names its key instead — see the custody
runbook in [`docs/dev/release-server.md`](../../docs/dev/release-server.md).

## Phases

- **boot** — flash the image to a scratch disk, boot it under OVMF, assert the kernel/systemd
  banner reaches the serial console, the first-boot wizard announces its URL + one-time token,
  and the token gate answers. Also asserts machine-id is stable across a plain reboot (#895) —
  the empty-baked image with no restore mechanism would regenerate a new one every boot — and,
  across that same reboot, that journald follows the restored id (#1659) and writes the one
  persistent journal home, the `/data/pithead/journal` bind, with the boot list intact (#1791:
  the `/var` overlay used to race the bind for `/var/log/journal`, and a boot that lost was
  missing from `journalctl --list-boots`).
- **update** — build a v2 bundle, `rauc install` it, boot the spare slot, and assert the whole
  A/B contract: an uncommitted slot auto-rolls-back, `rauc status mark-good` makes the update
  stick across a reboot, and `rauc status mark-bad booted` still rolls off a committed version.
  Also asserts `/data` grew to fill the disk, and that host identity (SSH host-key fingerprint,
  machine-id) survives the A/B swap (#894/#895) — both live on `/data`, untouched by the slot
  swap.
- **install** — boot the image as removable media beside a blank disk, run the disk installer,
  then boot the target and prove the copied system is COMPLETE — the `/var` overlay made an
  incomplete copy easy to produce and invisible to every other phase. Then the reinstall leg:
  `/data` must survive a second install over the same disk, and the three-way wipe choice
  (`keep`/`data`/`all`) is asserted on the raw partition. A previous 1.x `xmrig_proxy` setting
  must appear under `xvb` in the reinstall pre-fill, never survive under its removed name. The
  restore leg moves a real encrypted archive to a fresh disk and requires the running stack to
  carry the original payout wallet and Tor onion identity.
- **provision** — submit a config through the wizard's real HTTP flow and require the STACK to
  come up: wizard accepted, setup ran, images pulled and verified, containers running, dashboard
  served, Tor-only egress actually enforced, built-in miner up. Before the successful attempt, an
  unreachable remote node must be refused by preflight with its safe form values retained; a
  separate injected post-validation setup fault must open a recoverable failed page and retry
  with those values. The successful wizard submission names the appliance `fixture-box`; the
  running kernel, rendered dashboard address, served certificate and active mDNS service must all
  agree on that identity. After provisioning, the dashboard drives a benign apply, a typed approval
  and its missing-token refusal, structured doctor output, a capped/redacted p2pool log tail and
  the wallet-log refusal, then an encrypted backup; the stack and dashboard must answer again after
  the backup. Doctor must still return every structured row as an applied diagnostic when its own
  exit is nonzero with monerod deliberately stopped. A day-two `fixture-next` hostname preview must
  require the sensitive-change approval and leave the kernel name, mDNS activation, certificate and
  live config byte-for-byte unchanged. Missing and wrong approval identities are refused. A fake,
  allow-listed callback then approves the host-generated preview; the changed kernel, dashboard,
  certificate and mDNS identity must survive both the unaided reboot and closing A/B migration
  update. A dashboard-password edit remains physical-presence-only. The fixture `curl` recognizes
  only its two fake Telegram calls and has no route to the real provider. Then the stack must return from a reboot with no
  hands on it, and the real commit gate — `pithead doctor --json` — must pass on that healthy
  stack yet refuse once a revenue service is down. The closing leg installs a `data_migration`
  bundle through `pithead os-update` and proves the migration hold: the chain services stay down
  until the slot commits, then start, with the pending marker consumed. After it, the floor-fallback
  leg (`data-floor-fallback-leg.sh`, #1393) installs a migrating bundle stamped with a version no
  release carries, so its slot cannot bring the stack up and falls back uncommitted: the previous
  slot's boot must put the `/data` floor back from the record the raise left, and the same fall-back
  with the record deleted must leave the floor alone and make `os-update` refuse with the
  failed-update premise.
- **rig** — answer `RigForge` on the same page and prove the other machine this image installs:
  it mines from the baked binary with no compile and no clearnet, starts no containers at all,
  and takes an A/B update — install, boot, self-commit on the miner running, persistence —
  exactly like a coordinator. (Uncommitted fallback is the update phase's to prove: a
  provisioned rig commits the moment its miner is up, so the uncommitted window closes by
  design.) A rig serves no dashboard, so one that silently never mines is invisible to
  everything except this.
- **media** — the physical-presence configuration channel (#786 sub-issue D): provisions via the
  ESP pre-seed path, then attaches a second removable stick carrying a changed `config.json` and
  reboots. Asserts the exact diff appears on the console (the changed wallet address in full, a
  changed secret only named, never shown), the countdown applies the change, the changed setting
  takes effect, and the stick is consumed so it cannot re-apply. A second reboot proves pulling
  the stick mid-countdown cancels the change instead.
- **fault** — power cuts mid-write and mid-commit, plus a corrupt bundle. A brick is
  disqualifying.
- **reset** — the shell-less box's last resort, never before run against a real disk: a
  provisioned machine runs the real `pithead factory-reset -y`, which arms the `pithead-reset`
  marker on the ESP and reboots; assert it comes back to the wizard with the provisioned config
  and old container images gone, the seeded dirs back, and a FRESH host identity (SSH host-key
  fingerprint, machine-id) — the reset tier keeps nothing of the old owner's. A second leg
  corrupts the data partition's ext4 magic and asserts the wedged-`/data` recovery reformats it
  rather than bricking.

`--keep` leaves the VM and disks for inspection; `--phase boot|update|install|provision|rig|media|fault|reset|all`
scopes the run. A failed assertion is recorded and the run carries on, so one bench boot collects
the whole battery; the run exits non-zero if anything failed. `all` means all eight phases,
including fault and reset, and the full run is required once for every RC candidate.

The provision phase's remote-node consumer row is mandatory and takes reserved, reachable test
nodes from `PITHEAD_OS_MONERO_NODE_HOST`, `PITHEAD_OS_MONERO_RPC_PORT`,
`PITHEAD_OS_MONERO_ZMQ_PORT`, `PITHEAD_OS_TARI_NODE_HOST`, and
`PITHEAD_OS_TARI_GRPC_PORT`. `PITHEAD_OS_MONERO_NODE_USERNAME` and
`PITHEAD_OS_MONERO_NODE_PASSWORD` may be empty when the test node allows it; when supplied they
must be disposable test-only credentials, never an operator credential. Supply these to the
root-run battery without overriding `HOME`. The row requires the host preflight and fake
second-identity approval to succeed, checks the current p2pool container's narrowly extracted
Monero and Tari endpoints, and binds the current-startup `uses chain_id` verdict to that Tari
endpoint (or its documented SOCKS loopback bridge). It then restores the original local-node
configuration. Missing node inputs are a counted failure, never a skipped release gate.

## Static verification

`tests/os/verify-image.sh` is the cheapest gate and runs without KVM — it mounts a built image
read-only and checks that no test material shipped, that every baked fix is in the artifact, and
that the boot path's files sit where the firmware and GRUB will look.

```bash
sudo tests/os/verify-image.sh os/rauc/build/system.img          # release: test artifacts REFUSED
sudo tests/os/verify-image.sh os/rauc/build/system.img --test   # harness build: SSH key expected
```

## Soak probe

`tests/os/soak-probe.sh HOST LOGDIR [--start]` is the 7-day unattended soak's daily reader
(#1652): one non-interactive, read-only SSH session whose remote command is fixed in the script,
one line per day appended to `LOGDIR/soak.log`, scored against the pass condition ruled on the
issue (one boot, restart counts and start times flat, every container running and — except
`xmrig-proxy`, #1098 — healthy, exactly the probe's own login since the previous read). Each
read records the journal cursor it reached in `LOGDIR/ssh.cursor`, and the next read counts logins
from there, so nothing falls between two days and nothing is counted twice; a count of 0 fails
naming the instrument, since the probe's own login must be there. `--start` writes the day-0
baseline — its own line reads `window=25h` and carries a rule-4 FAIL from the setup logins, so day
0 is the baseline, not a soak day. Only `--start` writes `day0.env`; a cron read never does, so a
restart in the window's first hours can never be absorbed into the baseline it is scored against.
Every line carries `read=N`, its `soak.log` line number, because the first cron read lands under
24 h after `--start` and shares `day=0` with the baseline line; each run's raw readings are kept as
`LOGDIR/readN.env`. `--self-test` proves the verdict over canned readings, then drives the script
three times through a stubbed `ssh` to prove the baseline survives a cron read, without a box. Run
it from a cron line on the build host, never from a resident session.
