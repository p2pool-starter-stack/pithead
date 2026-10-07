# Appliance image harness

Tier-4 tests for the `pithead-os` appliance image (#77 phase 2): the properties only real
firmware and a real A/B updater can prove. The compose/CLI stack is covered by the other
tiers ([`docs/dev/testing-strategy.md`](../../docs/dev/testing-strategy.md)); this harness
also runs a native Quadlet Monero RPC fixture during `provision`. The rendered unit uses the
guest’s current Monero image, with separate data, a separate container name and loopback host
ports on a private IPv4-only managed bridge without a default route or external DNS.
Routing and disabled IPv6 are verified before the daemon starts. Outgoing peers are disabled,
and the fixture advertises no existing onion identity; its real zero exercises cold-start
visibility, not synchronization. It checks authenticated local admin access, the restricted
network listener, restricted public-RPC selection, P2P advertisement, fresh and expired health
observations, and a fresh run after restart. A failed P2P probe reports a bounded stage and
error code, with numeric header metadata; it prints no address, credential or raw response.
An unavailable or malformed probe remains failed proof.
The bounded P2P decoder validates up to four txpool notifications that Monero can send
before the handshake response; none can substitute for that response. Required node identity
and core sync fields must decode before an omitted or zero RPC port can mean suppression.
The Compose leg accepts that suppression only with an active P2P proxy and separately proves
restricted public-RPC selection; this unproxied native fixture requires port 18081.
Cleanup removes only the fixture unit, container, its client container, private network and
scratch files. The healthy-baseline
fault and recovery proof remains the Compose
`monero-stranded` job. The appliance harness covers EFI boot, the first-boot wizard window,
install-to-disk, the rig role, and the update → commit → rollback cycle that is the phase-2
exit criterion.
The stable `run.sh` entry point loads shared helpers from `lib/` and phase implementations from
`phases/`; `selftest-run-modules.sh` checks the complete load order without starting a VM.

The opt-in `tor-heal` phase provisions a local-node guest and faults only that guest's Tor.
It retains the production timers: 90 minutes with auto-heal disabled, then up to 95 minutes
with it enabled. It requires the first-round diagnosis within 25 minutes, a host recovery
result, a saturated state backup, cleared new state, unchanged onion keys and healthy Tor.
The guest discovers its dashboard network's IPv4 gateway through Podman network inspection
for a guest-local alert sink. It restores its original config and state on exit, copying
state only after Tor stops. Failures report the current stage, bounded command logs and
the restoration result separately from the test result; no shared Tor is poisoned.

It needs a Linux host with KVM, libvirt and qemu, and root (the bench, not CI):

```bash
sudo cp /root/.ssh/pithead-os-test.pub /tmp/pithead-os-test.pub
# Publish the five first-party images under the tag the appliance will ask for, then point the
# build at that registry. PITHEAD_REGISTRY_CA is needed only when the registry is TLS; it is baked
# for both Podman pulls and the containerized Cosign verification.
PITHEAD_REGISTRY=<host:port> PITHEAD_REGISTRY_CA=<ca.crt> PITHEAD_REGISTRY_COSIGN_PUB=<cosign.pub> \
    os/build-image.sh --ssh /tmp/pithead-os-test.pub # battery runs as root and uses root's key
os/rauc/mkimage.sh --dev                      # bootable image -> os/rauc/build/system.img
sudo env PITHEAD_REGISTRY=<host:port> PITHEAD_REGISTRY_CA=<ca.crt> PITHEAD_REGISTRY_COSIGN_PUB=<cosign.pub> \
    tests/os/run.sh --image os/rauc/build/system.img
```

`sudo` resets the environment (`env_reset`), so the override has to be passed THROUGH it — the phases carry those inputs through both `_build_image` and its static image verification, so an exported variable that sudo drops produces exactly the zero-container appliance this avoids.

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
`PITHEAD_REGISTRY_CA` and `PITHEAD_REGISTRY_COSIGN_PUB` are masked out of the tail from the environment, literally and without a
regex — the failing image ref survives, because which ref failed is the diagnostic and the bench
host is not. Under `sed` the value's own characters were part of the program: a `|` dropped the
whole tail, and a `\` or `[` leaked the raw host while still looking masked.

`tests/os/tor-health-evidence.sh` covers a third row the same way (#2359, a recurrence of #1945's
unresolved half): the restore leg's source-provisioning machine can fail with tor never becoming
healthy, and the only evidence any battery captured for it was the compose orchestration's own
verdict ("dependency tor failed to start") — never tor's own log, so nobody could tell why the
healthcheck itself failed. `backup_failure_evidence` now also dumps tor's container status, its
own healthcheck verdict, tor's bootstrap and warning lines from its whole log, and the log's tail.
A dump whose `ssh` fails says so, with the ssh error, instead of printing an empty section. The
restore leg reds its row and dumps as soon as a provisioning unit ends `failed`, before it takes the
backup (#2725). The backup restarts the stack through `pithead-boot`, and on an unhealthy tor
`pithead-boot` reboots the guest, which erased job 1194's evidence. The provision phase's onion-exposure leg calls the same dump,
after the tail of the refused `./pithead apply -y` output, when that apply fails (#2680).

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
  and the token gate answers. Assert serial getty is active on the guest's UART; give its installed
  condition a type-0 port for five minutes and require an inactive unit with no restarts or terminal
  errors, then restore the UART, require the unit active again and check a clean hangup respawns
  the login prompt. Also assert
  machine-id is stable across a plain reboot (#895) —
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
  (`keep`/`data`/`all`) is asserted on the raw partition. After Fresh Start returns to the
  installer, wait up to 180 seconds for the setup page before the remaining wipe and plant
  writes; SSH readiness alone precedes firstboot's read-only target probes. A previous 1.x `xmrig_proxy` setting
  must appear under `xvb` in the reinstall pre-fill, never survive under its removed name. The
  restore leg uploads the checked-in encrypted v1.20.0 fixture to an existing appliance disk and
  requires its running stack to carry the prior-release wallet, Tor identity and secrets while
  both the fixture's and the target's chain-data sentinels survive. The fixture's removed 1.x
  `xmrig_proxy` settings must move to `xvb` unchanged without leaving a `config.json.bak-1x`,
  and `telegram.control` must be dropped.
- **setup-defaults** — a fresh 40 GiB guest accepts the wizard defaults without a Tari override; proves Tor sync, XvB off, persisted choices, a generated working dashboard login, and firstboot/system journals free of bcrypt credentials.
- **provision** — submit a config through the wizard's real HTTP flow and require the STACK to
  come up: wizard accepted, setup ran, images pulled and verified, containers running, dashboard
  served, generated login authenticating, firstboot and system journals free of bcrypt credentials,
  built-in miner up. Journal reads must succeed and contain entries; the check never prints matched hashes. The Tor-only egress enforcement backstop — a real clearnet dial from a
  mining container, which must be DROPPED while the same container still reaches clearnet through
  Tor's SOCKS — runs on EVERY path through this phase, including the aborting ones, and reports RED
  when it could not be exercised on an otherwise-green phase. It used to sit at the tail of the
  successful path, so every battery to date skipped the product's stated security property silently
  ([#2059](https://github.com/p2pool-starter-stack/pithead/issues/2059)).
  The nightly KVM battery also makes a wallet-bearing XvB stats request through that Tor SOCKS
  path, up to three attempts 15 seconds apart because one Tor circuit can read-time-out against the
  remote host; every attempt refuses any socket but the Tor SOCKS. The leg runs inside the
  reserved-node leg, after the approval whose synced nodes release the sync gate and before the
  restore that re-holds it: on the guest's own unsynced chains the gate re-stops the proxy every
  30 to 45 seconds, and a leg that restarted it lost the P2Pool restore to that cycle
  ([#2733](https://github.com/p2pool-starter-stack/pithead/issues/2733)). Before the actuation and
  again before either normal or fallback P2Pool restore confirmation, it waits up to 300 seconds
  for the gate to read released with the proxy running in two consecutive samples. Each guest read
  is capped by the remaining deadline, and a late result cannot confirm readiness. It then invokes the controller's
  existing route actuator from P2Pool to XvB and back, reading the persisted dashboard state in
  the same process. This bounded injection
  proves appliance wiring and the dashboard state, not a share or hashrate transition: fresh guests cannot mine
  until their chains sync. Each of its verdicts is a counted row in the phase's own summary and none of
  them aborts it: a controller that cannot move the live route is one RED row, and the rows after it still
  run ([#2321](https://github.com/p2pool-starter-stack/pithead/issues/2321)). A failed transition
  attempts a fallback P2Pool restore only after the gate prerequisite passes; a held gate or an
  unconfirmed route is a counted failure. The leg never starts or stops the proxy: the gate owns it.
  The state, TCP and log diagnostics are read-only too. Without an applied reserved-node approval
  the leg does not run, and says so in one red row.
  Before the successful attempt, an
  unreachable remote node must be refused by preflight with its safe form values retained; a
  separate injected post-validation setup fault must open a recoverable failed page and retry
  with those values. The successful wizard submission names the appliance `fixture-box`; the
  running kernel, rendered dashboard address, served certificate and active mDNS service must all
  agree on that identity. The guest carries an unrouted documentation-range global IPv6 address
  and a ULA before submit; after provisioning, the pinned site, LAN v4 and ULA binds/listeners,
  refused global curl and dashboard-listener doctor verdict must agree that no global address is
  served. Doctor's separate stratum public-IP row remains a WARN. The dashboard then
  drives a benign apply, a typed confirmation and its missing-confirmation refusal, structured
  doctor output, a capped/redacted p2pool log tail and the wallet-log refusal, then an encrypted
  backup; the stack and dashboard must answer again after the backup. Doctor must still return
  every structured row as an applied diagnostic when its own exit is nonzero with monerod
  deliberately stopped. A day-two `fixture-next` hostname preview must require typed `APPLY` and
  leave the kernel name, mDNS activation, certificate and live config byte-for-byte unchanged
  when it is omitted. A confirmed change must apply and audit without a second approver; the
  changed kernel, dashboard, certificate and mDNS identity must survive both the unaided reboot
  and closing A/B migration update. A dashboard-password edit commits through the panel behind
  typed `APPLY` and the approval envelope, after its preview names the lockout and console-login
  costs; the new login must read the dashboard, and the fixture password is restored the same way.
  The shared dashboard control poller records POST and poll metadata on stderr: timestamp, route,
  curl exit code, HTTP status, response size, JSON/error presence, UUID and allowlisted result
  status. A refused or untrackable POST and an exhausted deadline also capture the guest control
  unit's state, restart/exit counters and queued/claimed request counts, with the existing
  20-second SSH probe deadline (`SSH_PROBE_TIMEOUT` overrides it). Correlate these with the
  runner's per-boot guest journals and control timeline before attributing a missing preview to
  the guest or the harness. Request bodies, free-text errors, preview values and credentials are
  excluded; diagnostic output never substitutes for the preview or typed approval assertions.
  The day-two Tari-mode prerequisite records a read-only Caddy baseline snapshot, and another
  if its existing config-read retries fail, before later reboots replace the evidence (#3001).
  The snapshot includes container running/restarting/OOM/exit state, the last 40 daemon log
  lines classified by allowlisted error phrases and Caddyfile line numbers, and the first 200
  configuration lines represented only by directive names and token counts. Config reads stop
  at 64 KiB, as does each Podman capture; truncation and unavailable probes are explicit. Both
  Podman probes have a four-second
  deadline inside the normal 20-second SSH probe deadline. Auth entries, config operands,
  arbitrary error text and local topology are excluded. An unclassified log line retains only
  its level and byte count; this snapshot does not establish an original cause or repair.
  The unreadable-config verdict and switching assertions remain binding.
  Before each host-side `pithead apply` the battery drives, it waits for the control spool to hold
  no queued or claimed request and reds the row if it never drains, keeping the harness's phase
  boundary deterministic. Apply does not stop an in-flight runner (#2363). Then the
  stack must return from a reboot with no
  hands on it, and the real commit gate — `pithead doctor --json` — must pass on that healthy
  stack yet refuse once a revenue service is down. The closing leg installs a `data_migration`
  bundle through `pithead os-update` and proves the migration hold: the chain services stay down
  until the slot commits, then start, with the pending marker consumed. Tari is then stopped on the
  committed slot (`appliance-chain-fault-leg.sh`, #2588): `pithead status`, `pithead doctor` and
  the dashboard's `Tari DOWN` badge must report it, and `./pithead up` must bring all three back.
  The badge must stay absent before the running dashboard's `TARI_NODE_DOWN_AFTER_SEC`
  debounce (900 seconds when unset) and appear within that debounce plus 180 seconds.
  Clock readings require successful numeric output; a failed initial clock refuses injection,
  and a failed or backward clock during polling fails timing and proceeds to recovery.
  The negative control requires a readable pre-debounce sample. Up to three consecutive
  unreadable samples are tolerated; a readable sample resets that count. An early `Tari DOWN`
  badge fails immediately and proceeds to recovery. A fourth consecutive unreadable sample
  or no readable pre-debounce observation fails separately. Failure messages record elapsed
  seconds and the badge verdict or read error, without dumping the full dashboard state. Unreadable, invalid or out-of-range debounce
  settings (the test accepts 1–3600 seconds) fail before fault injection; the guest policy
  is never shortened.
  After it, the floor-fallback leg (`data-floor-fallback-leg.sh`, #1393) installs a migrating
  bundle stamped with a version no release carries. Its copied build tree opts into the
  harness-only synthetic compose path, names its compose file explicitly, uses the resolved
  signing material, and records the file hash in `COMPOSE_SOURCE`, so the build does not need a
  git origin or a local dev-key directory. The
  resulting slot cannot bring the stack up and falls back uncommitted: the
  previous slot's boot must put the `/data` floor back from the record the raise left, and the same
  fall-back with the record deleted must leave the floor alone and make `os-update` refuse with the
  failed-update premise. The power-cut leg (M10, #2067) then cuts power three times WHILE the
  provisioned stack is live — every earlier power cut in the battery landed on a bare guest
  (`fault`) or was a clean reboot; this is the first that hits a provisioned one. After EVERY cut,
  asserts every container returns, the image store stays runnable (the #1029 class — present, digest-matched
  and unrunnable — checked the same way the product's own `repair_broken_image_store` checks it),
  monerod stays readable at or above the height read and flushed to disk just before that cut
  (its default db-sync-mode does not fsync each block (batched flushes), so an unflushed height
  is not owed back; #2557), and the miner and the boot-gated slot commit both survive. A KVM
  guest never clears the sync gate (#2063), so this runs against the held (still-syncing) stack
  rather than the full remote-node repoint M10 describes on real hardware — #2067 allows that for
  a first version.
- **rig** — answer `RigForge` on the same page and prove the other machine this image installs:
  it mines from the baked binary with no compile and no clearnet, starts no containers at all,
  and takes an A/B update — install, boot, self-commit on the miner running, persistence —
  exactly like a coordinator. (Uncommitted fallback is the update phase's to prove: a
  provisioned rig commits the moment its miner is up, so the uncommitted window closes by
  design.) A rig serves no dashboard, so one that silently never mines is invisible to
  everything except this. The reboot leg applies `max_temp_c` through the control path, waits
  for that change's provenance on the timer-refreshed feed, then checks the value and unchanged
  revision/change ID after reboot. Feed reads retry up to 12 times, five seconds apart; missing
  provenance fails the leg. A power-cut leg (M13's rig half, #2067) then destroys the guest
  mid-mining and asserts the same "mining unaided" fact off a real
  `virsh destroy` and that the slot is still committed afterwards. Its share leg (#2063) closes
  with the one thing every other row here cannot show: an ACCEPTED share. It boots a second,
  concurrent guest as a remote-node coordinator (`stack`'s own #2062 helper, from the SAME image —
  no second build), re-points the already-proven rig at that guest's stratum through the "Set up
  again" menu entry, and reads the coordinator's own `/api/state` until BOTH the rig's worker and
  the coordinator's built-in miner show `accepted > 0`. A bench with no reserved remote Monero node
  counts it a `missing` leg skip, the same env vars the `stack` phase needs.
- **rigmedia** — M14, #1829/#2069: the other rig a user can have. Boots the image as removable
  media beside a blank internal disk (the install phase's own boot shape, USB bus,
  `removable=on`) and answers `RigForge` without ever installing. Asserts the rig mines from the
  stick, no containers, volatile journald, an unaided reboot returns it mining, and the blank
  disk stays byte-for-byte untouched. Reaching the wizard again from a stick-run rig needs the
  bootloader path (#1318) and is not this leg's job.
- **media** — the physical-presence configuration channel (#786 sub-issue D): provisions via the
  ESP pre-seed path, then attaches a second removable stick carrying a changed `config.json` and
  reboots. Asserts the exact diff appears on the console (the changed wallet address in full, read
  directly from the serial file so an early match cannot be lost to a broken pipe, a
  changed secret only named, never shown), the countdown applies the change, the changed setting
  takes effect, and the stick is consumed so it cannot re-apply. A second reboot proves pulling
  the stick mid-countdown cancels the change instead.
- **fault** — power cuts mid-write and mid-commit, plus a corrupt bundle. A brick is
  disqualifying. A closing leg (the #1029 class, #2067) boots a FRESH guest and destroys it while
  its very first boot is loading the baked container images from the archive — the interrupted
  write a real USB stick produces, on a disk this harness can actually destroy mid-write. The bar
  is the same as #1029 itself: the next boot either repairs the image store or refuses with a
  legible console message, never silence, and the wizard must still serve afterwards.
- **reset** — the shell-less box's last resort, never before run against a real disk. Leg 0 runs
  the cheap tier first, on the same provisioned guest: `pithead config-reset -y` must clear
  `config.json`/`.env`/`Caddyfile` and the Tor-only egress firewall, re-arm the first-boot wizard
  while `pithead-boot` stands down (the two systemd conditions come out opposite), and keep every
  data directory — asserted by resubmitting the same config through the wizard's real HTTP flow
  and requiring the monero chain directory to survive, monerod's height to resume at or past its
  pre-reset value (no resync), and the Tor onion address, read from the hidden-service hostname
  file rather than `.env`, to come back byte-for-byte unchanged. Leg 1 is the deep tier: the real
  `pithead factory-reset -y`, which arms the `pithead-reset` marker on the ESP and reboots; assert
  it comes back to the wizard with the provisioned config and old container images gone, the
  seeded dirs back, and a FRESH host identity (SSH host-key fingerprint, machine-id) — the deep
  tier keeps nothing of the old owner's. Leg 2 corrupts the data partition's ext4 magic and
  asserts the wedged-`/data` recovery reformats it rather than bricking.
- **image-upgrade** — boot the submitted appliance image, create a sparse loop-mounted XFS with
  reflinks under the disposable guest's writable data partition, verify and install the published
  v1.20.0 bundle without modifying it, then invoke the existing image-upgrade harness against the
  submitted images. The baseline uses remote Monero and remote Tari because v1.20.0 predates
  Tari-off mode, and keeps its five data dirs on a shared root beside the version dirs on the same
  reflink volume, the layout `pithead upgrade` needs before it deploys a fresh version dir. The phase replaces only the disposable candidate bundle's image public key with
  the tier's debug-registry public key, so submitted images are verified against the key that
  signed them. When `PITHEAD_REGISTRY_CA` is set, the signed candidate also carries that CA as
  `cosign.registry-ca.crt`, where `verify_release_images` and the harness read it. It runs the release-shaped stack under the CLI's existing test override inside the
  otherwise appliance-shaped guest. Its private volatile script is invoked through `bash`, so a
  noexec mount cannot prevent the gate from starting. It proves bundle trust (including a wrong-key
  refusal), exact old/new OCI revisions, upgrade and rollback, secrets, telemetry, worker return,
  and resumed hashes. The v1.20.0 rollback starts without the strict Tor-egress check, because that
  release cannot install the podman ruleset; the run records it as a counted by-design row that
  [#2696](https://github.com/p2pool-starter-stack/pithead/issues/2696) removes. Release-input preparation failures name only the failed sub-step, a redacted
  command, and its exit status. Downstream guest failures name only a fixed stage (including the
  mountpoint or loop-mount half of reflink setup) and integer exit status; command output, tokens,
  keys, signature material, and topology stay hidden. Its EXIT trap stops the stack, unmounts the
  XFS, and removes the sparse file.
- **stack** — one stack suite, two channel harnesses (#2062, `docs/dev/testing-strategy.md` § J):
  provisions a guest in remote-node mode from the first wizard submit (`monero.mode=remote` at an
  already-synced bench node; `tari.mode=remote`, or `off` per #1855 when no reserved Tari node is
  set) so the sync gate clears in minutes instead of never, then runs `tests/integration/run.sh` —
  the DIY gate that `release-gate.yml` runs and that has never once driven the appliance runtime
  (podman through the docker shim, read-only root, `/data/pithead`, the control runner as a systemd
  unit) — against it: a non-destructive `--check`, then `--lifecycle --fault-injection --hardening
  --auth-fail-closed` against the `remote-main-secure-tari` scenario. The first live remote-node
  coverage on either channel (#1446). Reuses the same reserved-node env vars as the `provision`
  phase's remote-node consumer row below; without them the phase records a counted `missing`
  skip (#2356) rather than a bare line, so a bench that cannot run it says so in the tally. Measured cost: about
  fifteen minutes to a mining guest, then about ten for the two DIY-gate invocations. The scenario
  invocation names `--scenario` on purpose — the harness's default is its whole 15-scenario matrix,
  nearly all `monero.mode=local`, which this guest has no chain for. Two parity rows are out of
  scope here for want of inputs this guest cannot give them: the `monero.mode=local` scenario
  (#2443, needs a seeded chain) and `--xvb-routing-smoke` (#2444, its probe discards its own
  diagnostics, so the red is unreadable).

`--keep` leaves the VM and disks for inspection; `--phase boot|update|install|provision|rig|rigmedia|media|fault|reset|image-upgrade|crossupdate|stack|all`
scopes the run. A failed assertion is recorded and the run carries on, so one bench boot collects
the whole battery; the run exits non-zero if anything failed. `all` means every phase except
crossupdate, including image-upgrade, fault, reset and stack, and the full run is required once for
every RC candidate.

Every phase is called through `_run_phase` (#2356), the one place `run.sh` invokes them from: if a
phase call adds nothing to the pass/fail count or any skip bucket — the shape a required input
being absent produces, when the phase's own code has nowhere to record that — the wrapper itself
counts it as a `missing` phase skip. And a run where every requested phase skipped this way is not
a clean pass: `0 passed, 0 failed` now prints "no requested phase ran" and exits non-zero, instead
of reading as an empty success. A run that executed at least one row, pass or fail, keeps today's
exit code.

The image-upgrade phase fails closed unless `PITHEAD_OS_MONERO_NODE_HOST`,
`PITHEAD_OS_MONERO_RPC_PORT`, `PITHEAD_OS_MONERO_ZMQ_PORT`, and `PITHEAD_OS_TARI_NODE_HOST` are
set, the same inputs the stack phase reads. These are endpoint names, never values committed to
the repository. The harness resolves each node host on the bench host with `getent ahostsv4` and
gives the guest only the first IPv4 address; a host with no IPv4 address fails as a
`monero-node-address` or `tari-node-address` input failure that does not print the host. The guest
script prints `stage=<name> passed` or `stage=<name> failed` (with `primitive=tcp zmq` or
`primitive=rpc http` for the remote-node probe) to its serial console and the harness log. These
lines never include a host or port. Local-chain directory
continuity is outside this lean-storage gate and tracked by
[#2176](https://github.com/p2pool-starter-stack/pithead/issues/2176).

The final summary carries the same missing/by-design/covered skip vocabulary as the integration
harness (`tests/integration/lib/skip-accounting.sh`, #1083/#1444), sourced rather than
re-implemented so the two tier-4 summaries read the same way (#2064). It prints the three buckets
separately — scenarios, phases, legs — and the class breakdown under them in the integration
summary's own wording, so the two can be compared line for line. A green `--phase all` ends with
its five skip rows accounted like this:

```
os harness: <N> passed, 0 failed
skipped: 0 scenarios, 0 phases, 5 legs
  of which: 3 missing (an input would have run it), 1 by-design (this run's mode excludes it), 1 covered elsewhere
```

The pass total is the part that tracks the run; the five skip rows are what `--phase all` always
enumerates — the rig phase's one by-design row, the update phase's three missing rows, and leg 4's
covered row. A bench whose reserved Monero node requires an RPC login adds a sixth, the provision
phase's reserved-node commit (`6 legs`, `4 missing, 1 by-design, 1 covered`; see the remote-node
row below). Narrower invocations print a subset and nothing else: `--phase update` drops the
by-design row (`4 legs`, `3 missing, 0 by-design, 1 covered`), which is the rig phase's,
`--phase rig` prints that row alone, and `--phase provision` prints only the reserved-node row,
and only on a credentialed bench.

A row that cannot apply to the guest under test is a named, counted skip, not a silently absent
row or a folded-in early return. Which class it takes is decided by one question, and the answer
is not a matter of taste: **could a different invocation of this same harness against this same
box have covered it?**

- `by-design` — no. A rig guest has no dashboard, control API or compose stack, so the
  dashboard-scoped legs cannot apply to it under any phase. Recorded at phase entry, before the
  first fallible step, because a fact known before anything runs must not be reported only by the
  runs that get far enough to reach it.
- `covered` — it was proven elsewhere in THIS run, and the reason says where. The update phase's
  legs 1-3 never provision, so nothing pithead-boot owns runs there; leg 4 provisions the same
  guest and asserts the commit verdict, so the row is recorded **after** leg 4, classed on what
  leg 4 actually did. A leg 4 that returned early downgrades it to `missing` — a skip that claims
  cover on a run where nothing covered it is worse than no skip at all.
- `missing` — yes, and this is the only class that is a gap. The held-chain release, the
  boot-menu version repair and the /data-floor restore (#2055 G1) are all pithead-boot's, all
  unreachable from `--phase update`, and all proven by `--phase provision` or `--phase all`.
  Calling them `by-design` would book a real, reachable gap as accepted.

This is distinct from the remote-node row below, where a missing input stays a counted
**failure**: the classes are for rows the configuration excludes, never for inputs the bench
forgot.

The provision phase's remote-node consumer row is mandatory and takes reserved, reachable test
nodes from `PITHEAD_OS_MONERO_NODE_HOST`, `PITHEAD_OS_MONERO_RPC_PORT`,
`PITHEAD_OS_MONERO_ZMQ_PORT`, `PITHEAD_OS_TARI_NODE_HOST`, and
`PITHEAD_OS_TARI_GRPC_PORT`. `PITHEAD_OS_MONERO_NODE_USERNAME` and
`PITHEAD_OS_MONERO_NODE_PASSWORD` may be empty when the test node allows it; when supplied they
must be disposable test-only credentials, never an operator credential. Supply these to the
root-run battery without overriding `HOME`. The login is a Monero-node credential, not endpoint
identity, but the dashboard carries it with the endpoint under the typed confirmation: the preview
warns without echoing either credential, then the confirmed commit stages mode, endpoint and login
together for the host-side reachability preflight. This never leaves local mode with a foreign
login attached to the still-running local monerod/wallet-rpc containers, or remote mode short the
login its own preflight needs. Before that edit, the fixture sets `p2pool.clearnet=true` host-side:
p2pool otherwise routes its Tari merge-mining connection through Tor, and Tor's exit policy refuses
a private address — which the reserved test nodes always are — while the dashboard cannot commit
that setting on an appliance. The row checks the current p2pool container's narrowly extracted
Monero and Tari endpoints and, for each nonblank proposed login part, that p2pool's live
`--rpc-login` carries it (compared on the harness, never printed). It then binds the
current-startup `uses chain_id` verdict to that Tari endpoint (or its documented SOCKS loopback
bridge). It then restores the original local-node
configuration. Missing node inputs are a counted failure, never a skipped release gate.

On a failed current-startup Tari round trip, the row first searches the full current P2Pool log
(not a retained tail), then records the opaque runner-selected provider ID, the first failed
runtime predicate as a bounded reason, and allowlisted Monero/Tari RPC and sync fields from the
guest's existing authenticated dashboard clients. Those readiness fields are diagnostic only: the
current-process `uses chain_id` handshake remains the pass assertion.

## Static verification

`tests/os/verify-image.sh` is the cheapest gate and runs without KVM — it mounts a built image
read-only and checks that no test material shipped, that every baked fix is in the artifact, and
that the boot path's files sit where the firmware and GRUB will look. It compares the shipped
compose with its stamped source after removing only the five first-party digest pins.

```bash
sudo tests/os/verify-image.sh os/rauc/build/system.img          # release: test artifacts REFUSED
sudo tests/os/verify-image.sh os/rauc/build/system.img --test   # harness build: SSH key expected
```

## Soak probe

`tests/os/soak-probe.sh HOST LOGDIR [--start|--read]` is the 7-day unattended soak's daily
reader (#1652). It streams `tests/os/soak-read.sh` in one non-interactive, read-only SSH
session. Keep `soak-probe.sh`, `soak-read.sh`, `soak-record.sh` and `soak-selftest.sh` together
when copying the probe into the test kit. The self-test also reads
`dashboard/mining_dashboard/helper/http.py`; preserve all five repository-relative paths
in copied kits (the four scripts under `tests/os/`) to exercise the real bounded HTTP helper. Nothing is installed in the guest.

Run `--self-test`, then `HOST LOGDIR --read` before opening the window. `--read` saves
`read.env` and `read.firewall.json` locally without creating a baseline or counting a soak day.
The KVM `provision` phase exercises this mode on its disposable provisioned appliance. Its
assertion requires measured memory and an egress table, plus every optional reading present
as a number or `?`; it does not prove seven days of mining. Run the scheduled daily probe
from the build host, never from a resident session.

Open day 0 with `--start` only after both chains are synced and no migration is pending,
as required by the kit's pre-soak step. `--start` refuses an absent or unreadable egress
table, or a live Monero/Tari first-sync clearnet exemption. An unreadable exemption check
also refuses the start. It preserves the attempted reading in `refused-start.env` and
writes no new baseline or start marker. The steady Tor-first rules must be present first.
A new `--start` opens a new window and resets the sampled memory maximum.

Each daily read appends one line to `LOGDIR/soak.log`, scored against these rules:

1. One boot: boot time and journal-directory count agree with day 0.
2. Container restart counts and start times remain flat.
3. Every day-0 container runs and is healthy, except `xmrig-proxy` health (#1098).
4. Exactly the probe's own SSH login occurred since the previous read; no interactive
   sessions occurred. Each read saves its journal cursor in `ssh.cursor`. The next read
   counts from that cursor, so no login falls between two reads or gets counted twice.
   A count of 0 fails because the probe's own login is the instrument's positive control.
5. Chain state, resources and useful mining are recorded, without gating the soak.
6. The `inet pithead_egress` table is present and its stateless ruleset hash equals day 0.
   An absent table, an unreadable listing or hash, or a changed hash fails.

The owner approved rule 6 and the sampled-memory definition on 2026-10-06. The firewall
collector checks `nft list tables`, then reads `nft -s -j list table inet pithead_egress`.
It hashes sorted-key JSON with SHA-256, excluding nft metadata, object handles and dynamic
set elements. Counters are omitted by `-s`. Static set elements and dynamic set definitions
remain in the hash. This proves sampled policy stability, not continuous enforcement or
packet delivery between reads. A missing daily line or a failed SSH read fails the soak.
The probe compares recorded UTC sample dates, including failed SSH attempts, to detect
skipped dates. It records their count as `missing_days` and fails that read with
`schedule:missing-days(N)`. A retry on the same UTC date preserves the gap; the next daily
sample can resume normal scoring. Unreadable or backwards timestamps record `?` and fail
the schedule check. Keep every day's line when assessing the whole soak window.

`--start` writes `day0.env`, `day0.firewall.json` and the start marker. Its own login count
uses the preceding 25 hours, so setup logins can make its rule-4 verdict fail: day 0 is the
baseline, not a soak day. Only `--start` writes the baseline; a cron read never does.
Every line carries `read=N`, its `soak.log` line number, because a read under 24 hours after
`--start` can share `day=0`. Read numbers identify records; recorded time determines daily
continuity. Each successful reading and its derived values are kept in `readN.env`, with
`sample_epoch` captured before SSH so the log timestamp and rate interval use the same clock.
On a rule-6 failure, `readN.firewall-baseline.json` and `readN.firewall-current.json` retain
both stateless listings beside that reading. An unavailable current listing is `?`.
These files contain local topology: keep them private. They and the logs use owner-only
permissions; neither firewall listings nor credentials appear in the daily summary.

The recorded readings are:

| Reading | Instrument and interpretation |
|---|---|
| Memory and swap | `/proc/meminfo` MemTotal, MemAvailable, SwapTotal and SwapFree, in KiB. Used memory is MemTotal minus MemAvailable. `mem_sampled_max_kib` is the maximum across sampled reads since day 0, retained across missing samples; it cannot measure peaks between reads. |
| Container resources | `podman stats --no-stream --format`, container name, memory usage/limit and CPU percent. |
| Chain size and growth | `du -sx -B1M` on the configured Monero/Tari directories resolved under `/data`, allocated MiB on that filesystem. Growth is the difference from the previous successful read when its recorded UTC date is the same or the preceding date and there is no recorded gap; MiB/day uses elapsed sample seconds. Day 0 has no rate. Missing readings, a failed SSH predecessor, or a skipped UTC date give `?` for both chains' growth and rate. With samples on days 0/1/3/4, day 3 records one missing day and unavailable growth/rate; day 4 resumes from day 3. Same-day retries cannot clear the gap. Negative growth remains visible. |
| Tari height | The local node's `GetTipInfo` through the dashboard's installed gRPC client. Remote/off Tari and unreadable readiness give `?`. |
| Useful mining | P2Pool local data-api 15-minute hashrate, cumulative shares found/failed and pool sidechain height; xmrig-proxy summary connected miners and accepted/rejected work counters. No worker identities are recorded. Proxy HTTP reads use the dashboard's bounded helper (1 MiB response cap, five-second timeout); oversized replies leave proxy readings `?`. |
| Privacy route | Egress presence/hash and Tor's cookie-authenticated bootstrap healthcheck. A successful check records 100%; incomplete progress is recorded when reported; unavailable progress is `?`. |

Every missing recorded value appears as `?` in the reading and summary. Missing daily
samples and failed SSH reads fail independently of rules 1–6; missing optional readings
do not gate the soak. `--self-test`
uses canned readings, pure instrument parsers and stubbed SSH to prove these contracts,
including clock-advanced missing-day recovery, failed SSH recovery, refusal to start with
a sync exemption and retention of mismatch evidence.
