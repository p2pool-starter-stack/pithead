# 2.0.0 release plan and the road after

Snapshot: 2026-09-24, about 21:00 UTC. Issue and PR states below are as of that time; the live
list is [#2602](https://github.com/p2pool-starter-stack/pithead/issues/2602) and the
`v2 - appliance` milestone, and where this page and GitHub disagree, GitHub is right.

Legend: **[r]** read at the cited file:line in this repository, or at the cited pithead or rigforge
issue, PR or commit; **[i]** inferred. bench-ci is a private repository: a claim that rests on it is
marked [i], and the bench-ci issue it names is a pointer for maintainers, not public evidence.
"Owner" is the repository owner; "operator" is whoever runs the release lane.

## Summary

- **What ships:** Tari 6.0.1-pre.0 with P2Pool 4.18.1 for the Tari 6.0 fork, with a one-way,
  size-checked, rewind-safe data migration; the first signed A/B appliance image; the LAN-only and
  reboot-safe egress perimeter; restore onto new hardware.
- **What blocks the cut:** the image-changing fixes in §2.1 that have not merged, each needing a
  tier-4 job on its head; the owner's ruling on the 53 open `v2 - appliance` issues, 14 of them
  filed after the triage in §4 [r milestone].
- **Critical path:** milestone ruling → serial merges with a tier-4 job on each head → frozen SHA →
  tier4-kvm `phases=all` → signed build and hardware battery → 7-day soak → release lane → publish.
- **Who decides:** the owner rules milestones, GitHub settings, credentials and hardware; the queue
  lands code with its tier-4 proof; the operator does the cut-day commits and the post-cut lane.

## 1. Scope: what 2.0.0 promises

1. Tari 6.0 fork compatibility as one pair (Tari 6.0.1-pre.0, P2Pool 4.18.1); a pre-2.0.0 install
   is off the canonical chain until it upgrades [r CHANGELOG.md:50-58; #1129].
2. The migration is one-way and documented as such: not interruptible, 5.3.1 cannot reopen the
   result, `backup --with-chains` first [r CHANGELOG.md:59-71].
3. The migration survives its own size: LMDB map headroom, exit 114 unmasked, phases logged
   [r #2593; PR #2621], and a free-space refusal before it starts: on the Compose path
   [r lib/pithead/37-kernel-tuning-and-preflight.sh:286-311; CHANGELOG.md:61-65; #2636, PR #2646 merged] and on the
   appliance's OS-update path [r #2645; PR #2666].
4. A node that followed the dead 5.3.1 branch past height 350,000 is rewound before it syncs
   [r #2618; PR #2628].
5. Remote Tari: the serving node upgrades first [r CHANGELOG.md:72-73].
6. The appliance: A/B signed updates; the migrating bundle is declared with
   `PITHEAD_DATA_MIGRATION=true` and `PITHEAD_MIN_OS_VERSION`, so a rollback below the floor is
   refused [r os/rauc/mkbundle.sh:39-53; docs/dev/appliance-release.md "Compatibility metadata and
   the data-migration floor"]; quadlets on the same Tari and Caddy pins as Compose
   [r #2624, PR #2629 merged; #2630, PR #2647 merged; os/quadlet/caddy.container:5].
7. Restore onto new hardware: the sync-gate latch is re-derived on the restored machine
   [r #2626; PR #2634]; a v1.20.0 remote-node backup restores through the wizard [r #2230, PR #2231
   merged].
8. Security perimeter: `*_lan_access` ports reachable from LAN sources only [r #2616; PR #2620];
   DIY Tor-only egress survives a reboot [r #2460, PR #2601 merged]; the appliance's egress table
   sits ahead of netavark's accept [r lib/pithead/02-tor-egress.sh:14-18].
9. Dashboard: a forked-off Tari node is detected instead of reading healthy for nine days
   [r #2464, on #2602's list].

## 2. The cut

### 2.1 What the frozen SHA contains

"Image-changing" means the row changes what runs on a box, so it needs a tier-4 job on the PR head
[r docs/dev/testing-strategy.md].

| # | Item | Issue → PR | State at snapshot | Evidence required |
|---|---|---|---|---|
| C1 | `CHANGELOG.md`: fold `[Unreleased]` (:12) into `[2.0.0]` (:174, dated 2026-09-06), re-date | #2602 | cut-day commit | tier 1 |
| C2 | `VERSION` 2.0.0; `dashboard/pyproject.toml` agrees | #2602 | done [r VERSION:1] | none |
| C3 | LMDB map headroom, exit 114 unmasked, phases logged | #2593 → #2621 | open, conflicting | targeted tier4-e2e |
| C4 | Dead-branch rewind before first sync | #2618 → #2628 | draft | targeted tier4-e2e; the rewind row needs a fixture tip ≥ 350,000 [i] |
| C5 | Free-space precheck, Compose path | #2636 → #2646 | merged | done |
| C5a | Free-space precheck, appliance OS update | #2645 → #2666 | draft | tier4-kvm |
| C6 | Quadlet Tari and Caddy pins equal to Compose | #2624 → #2629; #2630 → #2647 | merged | done |
| C7 | Restore re-derives the sync-gate latch | #2626 → #2634 | draft, conflicting | tier4-kvm `install` restore leg |
| C8 | LAN-only source guard on `*_lan_access` ports | #2616 → #2620 | open, conflicting | tier4-e2e and tier4-kvm |
| C9 | DIY egress firewall restored at boot | #2460 → #2601 | merged | done |
| C10 | Dashboard alert when the egress firewall is missing | #2599 → #2617 | draft, conflicting | tier4-kvm `provision`; or move to 2.0.x (R6) |
| C11 | p2pool RandomX fallback under the memory ceiling | #2562 → #2609 | merged; #2548 still open | re-proof #2548 on the next matrix run [i] |
| C12 | Forked-off Tari node detected | #2464 | no PR | targeted tier4-e2e |
| C13 | Bundle built with `PITHEAD_DATA_MIGRATION=true PITHEAD_MIN_OS_VERSION=2.0.0` | #2602 | cut-day | `verify-image.sh` on the artifact |
| C14 | Tari over Tor dials IP peers again | #2508 → #2611 | draft | tier4-e2e; measurement moves post-GA (R5) |
| C15 | Tari node and wallet run under an init | #2627 → #2659; #2657 → #2662 | node merged; wallet draft, conflicting | tier4-e2e |
| C16 | N-1 encrypted backup restores on the appliance | #2001 → #2177 | draft | tier4-kvm `install`; or 2.0.x (R6) |

`mkbundle.sh` refuses `PITHEAD_DATA_MIGRATION=true` without a `PITHEAD_MIN_OS_VERSION`
[r os/rauc/mkbundle.sh:52-55]. It does not detect a migrating build that forgot to declare itself,
which #2602's bullet 5 asks for; C13 is therefore a cut-day step, not a gate [r].

Closed since #2602 was filed, drop from its list: #2472, #2496, #2414, #2604, #2360, #1990, #2460,
#2562 [r].

### 2.2 Must be true before the SHA is frozen

| # | Condition | State at snapshot |
|---|---|---|
| P1 | Every image-changing row above merged with a tier-4 job on its head | C5, C6, C9, C11 and the node half of C15 merged |
| P2 | Milestone ruled: each open `v2 - appliance` issue is in the cut or moved | 53 open; 14 filed after §4's triage and not yet ruled [r milestone] |
| P3 | Both e2e benches on the canonical Tari chain | bench-ci#556 open [i] |
| P4 | A KVM bench can run the `image-upgrade` phase, else `phases=all` cannot complete | bench-ci#560 open [i]; the gate needs `cp --reflink=always` [r docs/dev/release-server.md:310] |
| P5 | The shared matrix rows are green or attributed | #2362 → PR #2371 (draft): three rows red on every matrix run, among them the fault-injection failover-arm row at `tests/integration/lib/run-faults.sh:4-8` [r #2362] |
| P6 | `make lint && make test` green on the cut commit | cut-day |

### 2.3 Merge order

The second PR to land on a shared file rebases [r PR diffs at snapshot]:

1. **#2371** first: until it lands, every matrix job carries the three red rows of #2362.
2. **#2621 → #2628**: both change `CHANGELOG.md` and `tests/stack/run.sh`.
3. **#2611 and #2673** both change Tari's transport in `build/tari/config.toml.template` and
   `build/tari/entrypoint.sh`, as does #2621's template; one design has to win before either lands
   (R5).
4. **#2617** after #2620: both change `lib/pithead/01-lifecycle.sh`, `08-uninstall-firstboot.sh`
   and `tests/stack/run.sh`.
5. **#2634**, **#2666**, **#2662**: independent of the above.
6. **#2464's PR**, once opened; #2606 (PR #2635) waits behind it.

Not on the SHA's path unless ruled in: #2394 (#1854), #2305 and #2428 (#1959, #2367), #2140
(#1271), #2419 (#2351), #2180 (#2057), #2503 (#2363), #2585 (#2579), #2614 and #2615 (#2557,
#2471) [r].

### 2.4 The operator lane after the cut

Any image-changing merge after the cut restarts this list [r #2602].

| # | Step | Pass condition | Source |
|---|---|---|---|
| 1 | tier4-kvm `phases=all` on the frozen SHA | every phase green | #1651 |
| 2 | Full tier-4 suite as a release submission | `bench-ci/tier4` success on the exact SHA; `release.sh` preflight requires it | docs/dev/releasing.md:156, :284 |
| 3 | Signed build with the release key and C13's environment | `PITHEAD_EXPECT_COMMIT=<SHA> verify-image.sh` passes and refuses a debug variant | docs/dev/appliance-release.md "Build variants", "Cutting a release"; manual-release-checklist.md:46 |
| 4 | Hardware battery M1–M10 (M11–M13 if the rig role changed) on a real box | results on the release issue; the recorded dev-image runs do not carry | docs/dev/manual-release-checklist.md:55, :81-87 |
| 5 | Soak decision | re-soak if boot path, quadlets, base images, kernel or a container image changed; pass condition written before the run | #1652 |
| 6 | Release-lane rehearsal: `release.sh --dry-run`, `make release --draft`, image, bundle and checksums attached | draft opened; the git tag is spent at `--draft` | #1653; docs/dev/manual-release-checklist.md:176 |
| 7 | Publish; post-publish smoke, including the upgrade from 1.20.0 | `make release-smoke` against the tag | docs/dev/releasing.md:441-452 |

The soak will not transfer from an earlier image [i]: C4 changes the Tari entrypoint, C15 the
Compose file and the quadlets [r PR #2628, #2659 and #2662 diffs], and either alone trips step 5's re-soak clause. Plan on seven days
from the flash of the signed image.

## 3. Risks that outlive the release

| Risk | What 2.0.0 does | What it does not close |
|---|---|---|
| **Tor connectivity** (#2508) | 6.0's `tor` transport dials onions only [r build/tari/config.toml.template:85-87; #2508]; PR #2611 dials IP peers through Tor again | No measured number until an observation run beats the 6.0.0 baseline; #2464 is the only detector [i] |
| **Egress firewall** (#855, #2460) | Appliance: an `inet pithead_egress` table at forward priority −5 [r lib/pithead/02-tor-egress.sh:14-18]. DIY: restored at boot [r PR #2601] | #855 stays open until a tier4-kvm `provision` run proves both egress rows; it waits on the probe fix in PR #2573 [r #855]. The dashboard's panel reads config, not host state (#2599); `doctor` is the host-state check [r #2599] |
| **Migration on real disks** (#2636, #2645) | Refuses to start without room for the compacted copy [r lib/pithead/37-kernel-tuning-and-preflight.sh:286-311] | An OS rollback does not touch the data partition [r docs/appliance.md:415], so it cannot undo a half-migrated database. Durations are measured on benches only [i] |
| **Upstream pre-release pin** | Pins `v6.0.1-pre.0-mainnet` by digest because 6.0.0 rejects canonical block 350,008 [r CHANGELOG.md:54-58] | When 6.0.1 final lands, the re-pin is an image change. #2480 (a new Tari release never becomes work) means nothing will announce it [r #2480] |

## 4. Milestone triage, 2026-09-24

173 open issues across pithead, rigforge and bench-ci were briefed and adversarially verified; the
briefs that held were posted on their issues. The owner authorized the milestone
moves; the operator applied them on 2026-09-24:

- **Closed** with merged-PR or on-develop evidence: pithead #2457, #2321, #1897, #1866, #1886,
  #911, #2330; bench-ci #584, #540 [r].
- **Moved into `v2 - appliance`:** pithead #2593, #2575, #2470 (since closed by PR #2660), #2407,
  #2379; bench-ci #556 [r].
- **Moved out:** #2633 → `v2.x - post-GA`; #2632, #2631 → `maintenance & gates`; #2466, #2384,
  #2499 → `v2.x - post-GA` (from Sovereign UI); #2476 → Sovereign UI [r].
- **Left for the owner:** the trackers #940, #1875, #797, #786 (briefs say done or duplicate);
  #2474 (confirm with #2057 first). #1998 closed with PR #2174 [r].
- Two briefs are void (#2605, #2532: the verifier aborted); re-run them before acting on either.

Issues in `v2 - appliance` filed after the triage, not yet ruled: #2639, #2641, #2645, #2649,
#2653, #2654, #2657, #2671, #2672, #2678, #2685, #2689, #2692, #2694 [r milestone].

## 5. The road after GA

No `2.0.x` or `2.1` milestone exists. Below, "2.0.x" means the first weeks after GA, inside
`v2.x - post-GA` or `maintenance & gates`; "2.1" means designed features with no home yet (R1).

**2.0.x: the first weeks.** Goal: a fresh appliance and an upgraded DIY host get through their first
OS update, first restore and first Tari stall without a shell and without losing data.

| Belongs | Why here |
|---|---|
| Whatever P2 moves out of the cut | user-visible on day one, none data-destroying |
| #2057, #1997, #2473, #2001 | the image-upgrade gate; 2.0.0 is the first appliance image, so its first customer is 2.0.1 [r CHANGELOG.md:174-177] |
| #2508's measurement | the fix ships in 2.0.0 (C14); the number needs a bench observation run [i] |
| #2436 (silent boot gate), #2462 (serial-getty loop), #2463 (certificate never covers a later IPv6 address), #2461 | hit by a fresh box [r titles] |
| #2458, #2459, #2349, #2465, #2498, #2497 | Tor guard self-heal, onion lookup churn, per-worker tokens, the forked-node postmortem, wallet health [r titles] |
| #2480 (pull from `maintenance & gates`) | the pre-release pin makes it a 2.0.x hazard (§3) |
| #1837, #2373 | first-update and first-restore surface |

Gate that ends 2.0.x [i, proposed]: 2.0.1 ships only through a green `image-upgrade` phase on a KVM
bench, and an upgraded install has taken 2.0.0 then 2.0.1 through the dashboard with chains and
secrets intact.

**2.1: the designed features.** Goal: everything the host shell can do, the dashboard can do, gated
and audited, and a remote node is first-class by name.

| Belongs | State at snapshot |
|---|---|
| #1959 (PR #2305), #2367 (PR #2428): every field editable, sensitive ones behind typed `APPLY` | drafts, conflicting |
| #2351 (PR #2419): remote node by LAN name | draft, conflicting |
| #1999 (PR #2175): multi-worker routing under load | draft, conflicting |
| #2384 (PR #2449), #2353 (PR #2422) | drafts |
| #2494, #2490, #2483, #2482, #2487, #912, #1837; rigforge #528, #533, #531 | designed, no PR (R1) |
| #786 appliance parity; #1319, #2437, #2438 onion stratum | trackers and designs |

Gate that ends 2.1 [i, proposed]: #786's inventory closes: every `config.reference.json` leaf has a
dashboard route or a written host-only reason.

**Sovereign UI: post-2.0.** Rebuild the dashboard and wizard on the Sovereign direction (#2478) without
losing a field, a gate or the WCAG 2.2 AA pass (#1875). #2512 → #2513 → #2514 come before any child
view; #2547 is the coverage, accessibility and migration gate [r issue bodies].

### Ten issues most worth a worker after GA

1. **#2499 with #2464**: monerod and Tari "at tip, with peers"; the nine-day green tick (#2465).
2. **#2458**: Tor self-heal restarts tor and monerod without changing guards.
3. **#2384**: reboot and power off from the dashboard; PR #2449.
4. **#2436**: the boot gate is silent for about 16 minutes and reads as a hang.
5. **rigforge #526**: the xmrig overlay the sibling issues #527–#534 build on.
6. **#2346, #2345, #2344**: tier-4 legs for reset-dashboard, rotate-onion and rotate-secrets; PRs
   #2380, #2377, #2376.
7. **#2466**: rigs probed and badged for 30 days after they last mined.
8. **#2633, #2632, #2631**: one CI sweep; test-only.
9. **#2000, #1999**: fault injection over SSH and multi-worker load; PRs #2442, #2175.
10. **#2480**: a new Tari release never becomes work.

## 6. Rulings needed

The numbers are this page's own.

| # | Ruling | Default |
|---|---|---|
| R1 | No `2.1` milestone exists for the designed features in §5 | Keep them in `v2.x - post-GA`; the owner creates `v2.1` at GA if wanted |
| R2 | Existing PR or a fresh implementation, for every conflicting row in §2.3 | Resume the open PR; rebase, then one tier4 job on the rebased head |
| R3 | A KVM bench able to run `image-upgrade` (P4) | Provide one now; #1651, #2057, #1997 and #2473 need it |
| R4 | #2593's targeted tier4-e2e without a mainnet-database bench mode | Sufficient, per ruling 4 on #2593 |
| R5 | #2508: transport fix (#2611) vs #2653's stack-SOCKS design (#2673) | Pick one design; ship the fix in 2.0.0 and move the measurement post-GA |
| R6 | C10 (#2599), C16 (#2001): ship or move | C10 ships if #2620 lands cleanly; C16 ships if its tier4-kvm job is green by the freeze |
| R7 | #1854 / PR #2394 while #2626 is open | Block the merge: a restore that mines unsynced is what the gate exists to catch |
| R8 | #1959: in 2.0.0 or 2.1 | 2.1, unless the owner means the 2026-09-19 "every field editable" ruling for 2.0.0 [r #1959 comments] |
| R9 | #2343, #2344 tier-4 proof in 2.0.0 | No: land PRs #2378 and #2376 in the first weeks after GA |
| R10 | #1652 soak transfer | File-level delta at the cut; re-soak on any image change |
| R11 | Split candidates: #2485, #1872, #1837, #2497, #2491, #2487, #2458, #2463; rigforge #533 | Split each into the half that is small now and the half that waits |
| R12 | #1812, #1420 parked lane | Park, do not close |
| R13 | Merge queue on `develop`, or drop "require branches to be up to date" | One of the two |
| R14 | The 14 milestone issues filed after the triage | Rule each: in the cut, or moved |
