# 2.0.0 release plan and the road after

**What ships:** Tari 6.0.1-pre.0 + P2Pool 4.18.1 fork compatibility with a one-way, size-checked, rewind-safe data migration; the first signed A/B appliance image; the LAN-only and reboot-safe egress perimeter; restore onto new hardware. Prod (1.20.0) takes it first.
**What blocks the cut today:** ten image-changing PRs (#2621, #2628, #2636's, #2629, #2634, #2620, #2601, #2617, #2609, #2464's) none merged, six of them CONFLICTING; #2371 first so their e2e evidence is honest; the milestone (48 open) not yet ruled; #2593 carries no milestone.
**Critical path:** ruling on the milestone (owner, now) → serial merges with a tier-4 job on each head (~1.5–2 days of e2e queue) → SHA frozen ~09-26/27 → kvm `phases=all` (needs a KVM bench with `image_upgrade_ready=true`) → signed build + hardware battery (~2 days) → 7-day soak (almost certainly restarts) → release lane → publish ~10-06, prod migration the same day.
**What moves post-GA:** 26 of the 48 (CI speed, harness fixes, the image-upgrade gate and its riders, dashboard editability, Tor peering *measurement*, day-one defects that are not data-destroying); horizons 2.0.x → 2.1 → Sovereign UI, each with a gate.
**Who decides what:** owner rules milestones, prod, GitHub settings (merge queue, auto-merge), credentials, hardware (KVM flag, `tari-observe` tier, second e2e bench); the runner lands the code with its tier-4 proof; the operator seat does the cut-day commits, the kvm/battery/soak lane and the release rehearsal.

Legend: **[r]** read at the cited file:line / issue / PR; **[i]** inferred. Dates UTC, state as of 2026-09-23 ~23:30Z. Repo is pithead unless prefixed. No hostnames or bench names: "the primary", "the canary", "a KVM bench".

Contradictions between the drafts, resolved against the source: milestone count 44 vs 48 → **48** [r plan-context, `gh` milestone list]; PR #2629 "BEHIND" vs "MERGEABLE" → **mergeable, BEHIND** (both true, `gh`); #2634 → **BLOCKED**; #2611 → **mergeable, BEHIND**; #2593 milestone → **none** [r `gh`]; runner `max_in_flight` memory 12 vs live 60 → **60** [r config.toml:75]; "build-time check refuses an undeclared migrating bundle" (#2602 bullet 5) vs "gate exists" (draft A) → **partly**: `mkbundle.sh:39-53` refuses `PITHEAD_DATA_MIGRATION=true` without a `MIN_OS_VERSION`, it does not detect a migrating build that forgot to declare itself [r]; bench-ci#560 → **`maintenance & gates`** (frozen) [r `gh`]; no PR exists for #2464 [r `gh`].

## 1. The 2.0.0 cut

### 1.1 Scope — what 2.0.0 promises

1. Tari 6.0.x fork compatibility as one pair (Tari 6.0.1-pre.0, P2Pool 4.18.1); a pre-2.0.0 install is off the canonical chain until it upgrades [r CHANGELOG.md:51-67, #1129, #2604 closed].
2. One-way migration, documented as such: JMT rebuild then compaction, not interruptible, 5.3.1 cannot reopen the result; `backup --with-chains` first [r CHANGELOG.md:56-64].
3. The migration survives its own size: LMDB map headroom, exit 114 unmasked, phases in `docker logs tari` [r #2593 rulings; PR #2621]; a free-space refusal before it starts (161 → 216 GB at peak on both benches) [r #2636].
4. A node that followed the dead 5.3.1 branch past 350,000 is rewound by header hash at 350,000 before it syncs, once, idempotent [r #2618; PR #2628].
5. Remote Tari: the serving node must be on 6.0.x first [r CHANGELOG.md:60-61].
6. The appliance: A/B signed updates; the migrating bundle declared (`PITHEAD_DATA_MIGRATION=true`, `PITHEAD_MIN_OS_VERSION=2.0.0`) so a rollback below the floor is refused [r os/rauc/mkbundle.sh:39-53; CHANGELOG.md:151-170]; quadlets on the same Tari pins as Compose [r #2624].
7. Restore onto new hardware: the sync-gate latch is re-derived; a v1.20.0 backup restores through the wizard [r #2626, #2230].
8. Security perimeter: `*_lan_access` ports reachable from LAN sources only [r #2616]; DIY Tor-only egress survives a reboot [r #2460], its absence alerted [r #2599]; the dashboard cannot commit the perimeter [r CHANGELOG.md "Security"].
9. Dashboard: sync gate honours monerod's `synchronized` [r #2472 closed]; a forked-off Tari node is detected instead of reading healthy for nine days [r #2464, on #2602's list].
10. Prod (v1.20.0, stalled below the fork, no rewind needed) takes 2.0.0 first [r #2618 body; owner ruling 09-23].

### 1.2 The cut checklist (#2602, corrected and completed)

Owners: **runner** = the queue's agents; **operator** = the Mac-side runner's operator seat; **owner** = milestones, prod, GitHub settings, credentials, hardware.

#### The frozen SHA contains

| # | Item | Issue / PR | State today | Evidence required | Owner |
|---|---|---|---|---|---|
| C1 | `CHANGELOG.md`: fold `[Unreleased]` (:12) into `[2.0.0]` (:151, still dated 2026-09-06), re-date, Tari section with measured durations | #2602; #2593 ruling 2 | cut-day commit | tier 1 | operator |
| C2 | `VERSION` = 2.0.0, `dashboard/pyproject.toml` agrees | #2602 | done [r VERSION:1, pyproject:10] | — | — |
| C3 | Map headroom, exit-114 unmasked, phases logged | #2593 → PR #2621 | draft, CONFLICTING, RETURN r1 (body misrepresents jobs 906/209), job 950 cancelled; **#2593 has no milestone** [r] | targeted tier4-e2e on head (`build/tari`) | runner; owner milestones #2593 |
| C4 | Dead-branch rewind before first sync | #2618 → PR #2628 | draft, CONFLICTING vs #2621, head f91095bb, job 963 queued [r] | targeted tier4-e2e; rewind row needs a fixture tip ≥ 350,000 [i] | runner |
| C5 | Free-space precheck on the upgrade path (pattern `48-os-update-verbs.sh:134-142`) | #2636, no PR [r] | not started | tier 1 (stubbed df) + tier4-e2e on head [r #2636] | runner |
| C6 | Quadlets on the 6.0.1-pre.0 index digests, tier-1 parity check (`os/quadlet/*/tari*.container:7`, `36-quadlet-units.sh:130,206` still 6.0.0) | #2624 → PR #2629 | draft, BEHIND, one shell row red, kvm job 967 pending [r] | tier4-kvm `provision` [r #2624] | runner |
| C7 | Restore re-derives the #35 latch in `restore_apply()` only (R5) | #2626 → PR #2634 | draft, BLOCKED wait, no tier-4 job cited [r] | tier4-kvm `install` restore leg (job 929 found it) [r #2626] | runner |
| C8 | LAN-only source guard on `*_lan_access` ports (`33-render-env.sh:43`, `docker-compose.yml:283`, `36-quadlet-units.sh:142`) | #2616 → PR #2620 | draft, CONFLICTING; job 951 #2616 rows pass, 952 kvm queued [r] | tier4-e2e (DOCKER-USER) + tier4-kvm (nft table) | runner |
| C9 | DIY egress firewall restored at boot; prod ran 17 days open | #2460 → PR #2601 | draft, CONFLICTING; job 949 in progress; body cites nonexistent "#2598" [r] | tier4-e2e with the "pithead-egress.service removed" restore line [r report §4] | runner |
| C10 | Dashboard alert when the egress firewall is missing | #2599 → PR #2617 | draft, CONFLICTING, stacked on #2601; kvm 947 queued [r] | tier4-kvm `provision` | runner; **or move to 2.0.x (§3.1)** |
| C11 | p2pool `mem_limit` 1g → 4g (`docker-compose.yml:383-384`; RandomX fallback) | #2562 → PR #2609; closes #2548, #2567 | draft, CONFLICTING; 937 e2e PASS, 938 kvm cosign (bench-ci#568 CLOSED) | one matrix + one lifecycle tier4-e2e on head [r report §7] | runner |
| C12 | Forked-off Tari node detected (`tari_health.py`, three-signal verdict), guarded auto-restart | #2464 | branch @ 9aa928b4, **no PR** [r]; blocker bench-ci#556 moot, both benches canonical [i] | targeted tier4-e2e `--tari-stranded` | runner |
| C13 | Build metadata: bundle built with `PITHEAD_DATA_MIGRATION=true PITHEAD_MIN_OS_VERSION=2.0.0` | #2602 | gate validates the pair only [r mkbundle.sh:39-53]; invoking it is cut-day | `verify-image.sh` on the artifact | operator |
| C14 | Tari over Tor dials IP peers again (`config.toml.template:87` `tor` → `tor_tcp`; SOCKS still mandatory `:110-111`) | #2508 → PR #2611 | draft, BEHIND, Build-image red = TLS flake; tier submit 422 until bench-ci#584 [r] | `tari-observe` window (bench-ci#582) — **ruling: ship the one-line fix, measure post-GA (§3.1)** [i] | runner; owner applies the tier |
| C15 | v1.20.0 remote-node backup restores through the wizard | #2230 → PR #2231; #2001 → PR #2177 | #2231 BEHIND (three review rounds cleared), #2177 CONFLICTING; evidence needs #2622 [r] | tier4-kvm `install` + tier4-e2e | runner; **ruling: 2.0.0 or 2.0.x** [i] |
| C16 | Quadlet caddy pinned by digest like Compose (appliance.md:411-414) | #2630, no PR | rides #2629's parity loop [i] | same tier4-kvm job as C6 | runner; *drop-first* |

Closed, drop from #2602's list: #2472, #2496, #2414, #1414, #2604, #2360, #1990 [r `gh`]. Add #2618 (R9) and #2636 (R8) [r report §6].

#### Must be true before the SHA is frozen

| # | Condition | Evidence | State today | Owner |
|---|---|---|---|---|
| P1 | Every image-changing row above merged with a tier-4 job on its head | job id in each PR body; docs/dev/testing-strategy.md:38-50, runner README:464-479 [r] | 0 of C3–C12 merged | runner |
| P2 | Milestone ruled: 48 open in `v2 - appliance` [r plan-context]; each in the cut or moved; dups closed (#2548/#2567 with #2609, #2553 with #2503, PR #2424 closed) | milestone list empty of anything the SHA does not carry [r #2602] | not ruled; §3.1 is the proposal | owner |
| P3 | Both e2e benches on the canonical chain | bench-ci#556 closed | true tonight (fixed fact); bench-ci#556 still OPEN [r] → close | owner |
| P4 | A KVM bench advertises `image_upgrade_ready=true`, else `phases=all` cannot run `image-upgrade` | tiers.md in bench-ci:168-170 [r]; R2 | none does [r report §2]; bench-ci#560 sits in `maintenance & gates` (frozen) [r `gh`] | owner (hardware, milestone) |
| P5 | `tari-observe` tier applied on the primary (only if C14's *measurement* ships) | bench-ci#584 closed | OPEN, `maintenance & gates` [r] | owner |
| P6 | Fault-injection lane honest (predicate at `run-lifecycle.sh:136-141` reads `/api/state` fields never carried) | PR #2371 merged | CONFLICTING, job 939 on an older head [r report §2] | runner |
| P7 | `make lint && make test` green on the cut commit with the pinned shellcheck | appliance-release.md:471-483 [r] | cut-day | operator |

### 1.3 Merge order

Serial where a file is shared; the second to land rebases (R1: always resume the open PR, never fork [r prompts/base.md:40-44]).

| Step | Merge | Why this position | Unblocks / closes |
|---|---|---|---|
| 1 | #2371 (#2362) | test-only; otherwise every later e2e job carries two red rows and each fault resubmit burns ~35 min [r report §3 row 3] | honest evidence for steps 2–9; no fault resubmits until it lands |
| 2 | #2621 (#2593) then #2628 (#2618), then #2636's PR | all touch `build/tari/entrypoint.sh`, CHANGELOG, `tests/stack/run.sh`, `test-tari-lmdb.sh` [r report §4 row 4]; #2621 needs a re-proof job first | C3, C4, C5 |
| 3 | #2629 (#2624) (+ #2630 if kept) | independent of step 2; shares `36-quadlet-units.sh` with #2620 → land first [i] | C6, C16 |
| 4 | #2601 (#2460) → #2617 (#2599) | stacked; fix the "#2598" reference before merge | C9, C10 |
| 5 | #2609 (#2562) | compose `mem_limit`; highest fan-out [r report §4 row 7] | C11; close #2548, #2567 on the re-proof |
| 6 | #2622 (#2619) | test retry; wait for jobs 953/954 | evidence for #2231, #2177; waits `pithead-2230`/`pithead-2001` |
| 7 | #2503 (#2363) | CI green @ f23add30, e2e 933 SUCCESS, kvm 934 cosign → rerun kvm provision only | closes #2553 |
| 8 | #2585 (#2579) | 9 red rows in `test-cli-restore-hardening.sh`; job 970 queued; dead-pid stage file blocks adoption [r report §1.7] | closes bench-ci#538 |
| 9 | #2620 (#2616) | after step 3; cite 951's #2616 rows + 952 | C8 |
| 10 | #2634 (#2626) | independent; one tier4-kvm `install` job | C7 |
| 11 | #2464's PR (open it) | canary converged → blocker gone [i]; #2606 waits behind it (R7) | C12 |
| 12 | #2611 (#2508) | one-line transport fix; cite `config.toml.template:110-111`; no tier needed for the fix itself if the measurement moves [i] | C14 |
| 13 | #2231 / #2177 | after step 6; ruling on C15 first | #2230, #2001 |

Not on the SHA's path unless ruled in: #2394 (#1854), #2305/#2428 (#1959/#2367), #2140 (#1271), #2419 (#2351), #2180 (#2057; needs P4), #2612/#2614/#2615 (test-side; R3: no product change) [r report §4, §6].

### 1.4 The operator lane after the cut

Order from #1651 ("battery first, it is hours; the soak is seven days") and #1653 ("last of the three") [r]. Any image-changing merge after the cut restarts this list [r #2602].

| # | Step | Pass condition | Duration | Depends on |
|---|---|---|---|---|
| 1 | tier4-kvm `phases: ["all"]` on the frozen SHA; job id on #2602 | every phase green: boot, update, install, provision, rig, media, fault, reset, image-upgrade [r tiers.md in bench-ci:164-166] | 9 × 30–90 min = 4.5–13.5 h, solo tier [r tiers.md:118]; default timeout 150 min → pass `timeout_minutes` [i] | P4; #1651 |
| 2 | Full tier-4 suite as a release submission: final leg `status_gate: true`, `after` naming every other leg | App posts `bench-ci/tier4 = success` on the exact SHA [r bench-ci docs/operations.md:133-140]; `release.sh` preflight checks context, App slug and id [r releasing.md:155-157] | matrix e2e ~60 min + step 1 | step 1; P3 |
| 3 | Signed build: `build-image.sh && mkimage.sh && mkbundle.sh` with the release key and C13's env; `PITHEAD_EXPECT_COMMIT=<SHA> verify-image.sh` from the build checkout | verify-image passes, refuses a debug variant [r appliance-release.md:486-520; manual-release-checklist.md:46-52] | hours [i] | signing custody (owner) |
| 4 | Hardware battery M1–M10, M15, M16 (M11–M13 if the rig role changed) on a real box; results on the release issue | appliance-release.md:307-433 [r]; the 09-18/19 run on a dev image at 1b0da070 does not carry [r manual-release-checklist.md:83-86] | 2 days last time [r] | step 3's image on a stick |
| 5 | Soak decision (#1652): file-level delta between 1b0da070 (soak start 09-19 17:05Z, through 09-26) and the SHA | re-soak if boot path, quadlets, base images, kernel or a container image changed [r #1652 ruling 09-23 23:09Z]; pass condition = the six rules written before the run [r #1652 comment 1] | 0 days if it transfers; **7 × 24 h from the first daily line otherwise** | step 3's image flashed on the appliance |
| 6 | Release-lane rehearsal (#1653 rows 3, 4, 6–8, 10–11): `release.sh --dry-run`, `make release --draft`, attach image + bundle + checksums, consumer `os-update` on a box that did not build it | draft opened, both channels' artifacts attached, publish once; the git tag is spent at `--draft` [r manual-release-checklist.md:176-186] | 1 day [i] | steps 2–5; owner's publish rights |
| 7 | Publish; `main` fast-forwards; post-publish smoke incl. the upgrade from 1.20.0 on prod (prod first) | `make release-smoke` against the tag [r releasing.md:213] | hours + the prod migration (JMT ~40 min + compaction on a mainnet chain [r #2593 ruling 2]) | step 6 |

**The soak will not transfer** [i]: C4 rewrites the Tari entrypoint (container image), C6 the quadlets, C11 compose limits — each alone trips the re-soak clause. Plan on step 5 = 7 days from the flash of the signed image.

### 1.5 Critical path

Minimum merges to a frozen SHA, each with a tier-4 job on its head: **#2621, #2628, #2636's PR, #2629, #2634, #2620, #2601, #2617, #2609, #2464's PR** — ten, with #2371 first. Everything else in the milestone is a ruling (P2), not a merge.

1. **P2, the milestone ruling** (owner, today): 48 open, ~16 on the path above; the rest move or the queue keeps working them and the SHA never freezes [i].
2. **E2e throughput**: the lane was 94 % busy today; ten PRs × one 21–60 min job, serially, plus rebases and re-proofs for the six CONFLICTING ones [r report §3, §4]. With the canary canonical, ~1.5–2 days of queue if nothing is resubmitted twice [i].
3. **P4, a KVM bench with `image_upgrade_ready=true`** (owner, hardware): without it `phases=all` cannot complete and #1651 stays blocked; bench-ci PR #565 only improves the error text [r bench-ci#560].
4. **After the SHA**: kvm all (≤ 0.6 day) → signed build + hardware battery (~2 days) → soak (7 days) → release lane (1 day).

Realistic [i]: SHA frozen **09-26 to 09-27** if P2 is ruled tomorrow and the queue is not re-blocked; signed image on the appliance **09-28**; soak ends **10-05**; publish **10-06**, prod migration the same day. Without a re-soak (owner overrides the ruling) publish moves to about **09-30**. Every image-changing merge after the cut slips every date.

## 2. Foundation — the test fleet, the runner and CI tonight

### 2.1 The test fleet (bench-ci)

| Piece | Tonight | Source |
|---|---|---|
| Two e2e lanes | The primary (idle workload `pithead`, serves no nodes since 09-18) and the canary (node-serving, self-update canary). Both canonical tonight; bench-ci#556 still open. | [r bench-ci README "Decisions" 9, docs/operations.md:337-341; bench-ci#556] |
| KVM benches | `tier4-kvm` is `solo` (one job per bench, free-memory floor at boot); each bench now pushes to its own registry namespace, ending the cosign race that killed five KVM jobs today (930, 932, 934, 938, 874). | [r tiers.md (bench-ci):351-357; bench-ci#568 → PR #593 merged 23:16Z] |
| Three rigs, one per e2e job | Default `workers: 1` since tonight; two e2e jobs side by side with a rig spare; the runner reserves the rig and restores its miner config on every outcome. | [r PR #591 merged 22:45Z; README "Decisions" 3] |
| Node guard | KVM and matrix-e2e hold read leases on the shared nodes; node-serving e2e and `baseline-refresh` need the write; writer preference. A failed restore keeps its lease until an operator posts `POST /node-guard/release`; the refusal names holder, mode, age; the status page shows `OPERATOR ACTION` after 30 min (a 3.5 h stall today read `ok` before). | [r tiers.md (bench-ci):38-49; bench-ci#576 → PR #577; bench-ci#586 → PR #590 merged 22:36Z] |
| Canary as node provider | `@nodes` resolves at dispatch to the node-serving bench; a credential fingerprint refuses a mismatched dialer; a node > 50 blocks off the explorer tip does not serve. | [r docs/operations.md:337-345, 370-380; tiers.md (bench-ci):440-450; bench-ci#557] |
| Migration fence | A head pinning another Tari/Monero major than the bench's live checkout is refused unless `options.migrates_chain_data`; no routing to a matching peer. | [r tiers.md (bench-ci):96; bench-ci#559 closed, #562 open] |
| HugePages | 3072 × 2 MiB reserved at boot; `tier4-e2e` refuses a deploying job under 1296 free (a 186-page pool OOM-looped P2Pool today). | [r setup.md (bench-ci):20-26; tiers.md (bench-ci):117; bench-ci#569 → PR #574] |
| `tari-observe` tier | Isolated Tari+Tor for a `window_hours` observation against a baseline job's OFFLINE rate; merged, **not applied on the primary** → PR #2611 gets 422. | [r tiers.md (bench-ci):97-98, 120, 212-250; PR #582; bench-ci#584 open] |
| Gates nobody can run | `image-upgrade` needs `image_upgrade_ready=true` (none); reserved-node-by-name needs a name-shaped node fixture (none); the local-chain gate root needs 425 GB no bench has. | [r bench-ci#560, #371, #227; pithead#2057] |

What bounds throughput [r report §3, 13 runs 14:39–21:05Z]:

| Bound | Number | Cut | Status |
|---|---|---|---|
| The e2e lane is saturated | 361/386 min busy (94 %); queue wait is depth, not job length | second e2e bench with local pruned chains + one rig | devops, days; no issue [i memory is the question, `tier4-kvm` claims 22.5 GiB] |
| Job length by class | targeted+rig 21–25 min, no-rig lifecycle 16–18, fault-injection 35–38, matrix 60 | diff-class phase selection at submit (`options.phases`, `no_rig`, `mode: check`) | runner prompt table, ~7 min per eligible job; no issue |
| Fault-injection resubmits | 110 bench-min on one red row today | stop until #2371 lands | one prompt line; pithead#2362 |
| Third restart of the chain nodes per job | ~2 min/job | skip `restore_cmd` + 30 s recheck when the wrapper's proof passed | bench-ci#588 → PR #595 open |
| Rig probe interval | up to 5 min per transition | re-probe on release | bench-ci#589 → PR #592 merged |
| Registry tag race | 25+ min per wasted KVM job, five today | per-bench namespace | bench-ci#568 → PR #593 merged |
| Safety backup stops the stack | ~3 min/job | online backup | product change, no issue |

### 2.2 The runner (pithead-developer)

Loop [r README:100-130, 177-240; live config]: sweeps → bench-ci first → resumes → adoptions → capacity gate → pick → run → review, every 10 min. Pick ranks: bench-ci; `security`/`flaky`/`P1-user-facing`/`dependencies`; `P2-correctness`/`bug`; `v2 - appliance`; `maintenance & gates` (frozen). Oldest first within a rank.

| Rule | As it stands | Source |
|---|---|---|
| Freeze | `freeze_milestones` holds maintenance, post-GA and Sovereign UI until `v2 - appliance` is empty, on the resume path too | [r config.toml:74; README:198-206] |
| Freeze deadlock | a blocker of a wait in an open lane is picked whatever lane it carries; frozen waits do not thaw their own blockers (commit 0936010 tonight; live effect [i]). bench-ci#560/#540/#541 still need a re-milestone (R16) | [r report §1] |
| In-flight cap | `max_in_flight = 60` [r config.toml:75]. The report saw 40/40 with 19 parked or mis-resolved entries (cross-repo `Closes bench-ci#NNN` read as pithead numbers; dead-pid stage files). Runner fixes owed, no issue | [r report §1 tail] |
| Adoption | PR scans page to 200 (609e638); every `claim_branches` prefix counts, trust by author (0936010); an orphan PR closing only frozen-lane issues is held with them (a86bbd6); a PR whose issue is `blocked` on it is adopted (6694138); `operator-action` skips adoption by design (tick:2239) | [r commits; report §2] |
| Auto-merge | a "base moved" refusal arms `gh pr merge --auto`; needs auto-merge enabled on the repo — README:445 still says off everywhere; 20 refusals vs 53 merges today → merge queue or drop "require up to date" (owner) | [r fc48b55, b62c571; report §2] |
| Remote session hosts | opt-in `[runner] remote_hosts`, `remote_slots` (default 4); live config names no hosts, so it is off | [r bin/tick:209-262; config.toml:8-9] |
| One PR per issue | resume the runner's open PR on any claim branch, never fork; takeover re-pushes the same branch and closes the old PR as superseded (seven duplicate pairs in one day) | [r prompts/base.md:40-44] |
| Tier follows the path | `build/`, compose, rendering, control plane, deploy/restore, Tor, miners → `tier4-e2e` on the head; `os/` → `tier4-kvm`; a tier-1 string assertion is never enough (#2327 crash-looped tari) | [r README:459-480; testing-strategy.md] |
| Blind to outside accounts | nothing not opened by the owner or the runner's Apps is listed, read, labelled, closed or merged; `approved` by hand is the one grant | [r README:264-275] |
| Sessions ship code only | bench misbehaviour is a bench-ci issue, never a hand fix; rigs and locks are the runner's | [r prompts/base.md:32-38] |
| Plans burn to 90 % | a fan-out from an operator session draws the same window (75 agents starved the runner 21:44–22:20Z today) | [i memory] |

### 2.3 CI

pithead — the Shell job is the PR wall clock [r shell.yml:30; report §5]:

| Job | Now | Target | Issue |
|---|---|---|---|
| `tests/stack/run.sh` (serial; ~216 `control-run-pending` calls ≈ 40 %) | ~752 s, workflow 13–16.6 min | ~4 min via four contiguous shards | #2631 |
| `lint-sh` (one shellcheck over 343 files) | 351 s | 60–90 s via `xargs -P` | #2632 |
| Dashboard pytest (~100 s of real sleeps) | 134 s | ~30 s with faked intervals + `-n 4` | #2633 |
| Mini-stack scenario 12; first-boot journal suite | 123 s; 60 s | ~40 s; ~2 s | no issue |

Order: lint-sh → dashboard sleeps → run.sh sharding → mini-stack → control-run-pending (tier4-e2e). None is image-changing, so none restarts the soak — pin them if the cut's own PRs need faster CI [r #2602 last line].

bench-ci — `make check` = lint + test + openapi-check [r Makefile:18]; `make test` 339 s → 115 s on four workers (PR #587). No GitHub workflow any more: 15/15 runs died in 3 s on the spending limit, owner ruled it ignored, PR #594 removed it; `make check` in the worker and the reviewer's clean worktree is the whole gate [r bench-ci README:53].

### 2.4 Observability gaps

| Signal | Tonight | Gap / tracker |
|---|---|---|
| Node-guard holders, pending writers, lease held by a finished job | `/health.node_guard`, `GET /node-guard`, status page `OPERATOR ACTION` at 30 min | bench-ci#586 closed; local watcher's `GUARD-HELD-BY-DONE-JOB` retires once #590 is on every bench [i] |
| Idle e2e lane; partial fleet history when a peer is unreachable | watcher only; `GET /jobs?fleet=true` returns `peers` [r operations.md:264-271] | no status-page equivalent; no issue [i] |
| Chain height vs the canonical tip | admission compares to `tari_tip_url` within `tari_max_lag` [r tiers.md:440-450]; watcher `CHAIN-LAGGING` | page shows `live_stack.healthy` only; no issue [i]. Product side: #2464 |
| Why a tier is refused | — | bench-ci#560 → PR #565 (merge under the no-CI-gate ruling, R15) |
| Claim polling noise (6,057 `/node-guard/claim`/h); a nightly that did not run | — | bench-ci#578; bench-ci#534 |
| Rig reachability, disk under reserve, stuck self-update, job past budget | local watcher scripts on a 3-min poll, in no repo | belongs in the status page or the runner dashboard [i] |

## 3. Milestone triage and the road after GA

Rules applied [r]: the runner never cuts 2.0.0 — the owner does once `v2 - appliance` is empty (README:15); a MOVE parks the issue and its PR's wait (README:204-205); a KEEP is a promise to land it before the SHA freezes (#2602 last line); the runner is blind to outside-authored issues (README:300-308; #2454).

### 3.1 Triage proposal — 48 issues

**22 KEEP** (15 need code, 7 zero-code), **26 MOVE**. Two KEEPs are *drop-first*.

KEEP — the checklist rows C3–C16 above (#2593, #2618, #2636, #2624, #2626, #2616, #2460, #2599, #2562 + riders #2548/#2567, #2464, #2508 fix, #2230, #2630) plus:

| # | Class | Why the cut must carry it | Where it stands | Basis |
|---|---|---|---|---|
| #2602 | checklist | the cut's own list | bullets 1–5 open | [r 2602-body] |
| #1129 | fork umbrella, `release-blocker` | rows 12–18 unticked (pins across Compose and Quadlet, V1–V12 evidence, migration measured, commit-before-migration); closes with the cut | zero code; evidence in #2589/#2618/#2624/#2636 | [r #1129:12-18] |
| #1651 #1652 #1653 | GA gates, `release-blocker`, `operator-action` | runs, not code (§1.4 steps 1, 5, 6) | #1651 blocked on bench-ci#560 → re-milestone (R16) | [r bodies] |
| #2589 | fork evidence | #1129 row 14: real payload acceptance by a 6.0.x node (R10/R11 ruled) | no PR; dead-pid stage file blocks pick [r report §1.7]. **[i] alternative:** an accepted Tari submission in the frozen SHA's tier4-e2e Tari leg on mainnet is the same proof; owner may accept it in place of LocalNet V5 | [r #1129:14,22] |
| #855 | security, proof-only | code merged (#857, #2091; `02-tor-egress.sh:14-20`); open pending a tier4-kvm provision run on the current tip with `appliance-egress-leg.sh:112-127` passing — #1651's `all` run supplies it [i]; R18 moot | blocker landed as PR #2573, job 972 | [r issue855-comment] |
| #1854 | security + data safety | PR #2394's finding: the installer handoff persisted the encrypted archive *and its plaintext passphrase* on the ESP; the fix keeps both in root-owned volatile storage | resume live; 928 success, 929 failure | [r PR #2394] |
| #2362 | release gate (test-only) | two fault-injection rows red on every matrix run; a permanently red row blocks `bench-ci/tier4 = success` [i] | PR #2371 CONFLICTING (P6) | [r #2362; testing-strategy.md:19] |
| #2464 *(drop-first)* | the prod incident class | a forked node stayed healthy nine days; **if dropped**, 2.0.0 ships that blind spot; #2465 postmortem is post-GA regardless | branch, no PR (C12) | [r 2464-brief; memory prod-review] |
| #2630 *(drop-first)* | reproducibility | **if dropped**, an appliance installed after GA can pull a Caddy the soak never ran | no PR (C16) | [r #2630; appliance.md:411-414] |

\#2508 is **split**: the transport fix ships (C14); the acceptance (OFFLINE rate beaten tenfold, tiers.md:98) moves to 2.0.x because `tari-observe` is unprovisioned (bench-ci#584). Without the fix, 2.0.0's Tari peering is strictly worse than 1.20.0's [i].

MOVE — target `v2.x - post-GA` unless marked *maint* (`maintenance & gates`). The owner decides both the move and the target.

| # | To | Reason | What 2.0.0 loses | Basis |
|---|---|---|---|---|
| #2633 #2632 #2631 | maint | CI speed, no image change | PR wall clock stays 752 s / 351 s / 134 s; landing them never restarts the soak | [r report §5] |
| #2627 | 2.0.x | tari container has no init; zombie PID 1 on `docker stop` right after the migration (R4: regenerate via renderer, tier4-kvm) | first `down`/`apply` after a migration may hit the 60 s stop timeout | [r #2627] |
| #2610 | 2.0.x | `06-doctor.sh:126-132` says HugePages OK for any non-zero pool | doctor lies on a short pool; with #2609 the fallback runs in RAM instead of dying | [r 2610-brief] |
| #2606 | 2.0.x | blocked on #2464's PR (R7); egress.py split landed (#2635) | egress panel omits one hourly Tor-only explorer fetch [i] | [r 2606-comment] |
| #2599 | 2.0.x *(or keep as C10)* | panel is config-derived (`egress.py:244`), never host state; stacked on #2601 | a missing firewall for any cause other than reboot shows green; `doctor` still FAILs (`21-doctor-stack-checks.sh:68`) | [r 2599 brief] |
| #2595 | 2.0.x | interrupted recreate leaves `<id>_monerod`; PR #2623 needs a 3-expectation test fix (`test-tor-network.sh:774-779`) | monerod under a temporary name until the next `apply` | [r brief_2595] |
| #2588 | maint | coverage gap only; the app already reports a post-commit chain failure (`15-os-update.sh:85-90`); R12 | no automated V10 row | [r 2588-brief] |
| #2579 | 2.0.x | `16a-restore-safety.sh:111-123` whitelist drops `DASHBOARD_AUTH_HASH_B64`/`PW_FP`; regenerated from the plaintext | a restore re-derives the auth hash; the password still works [i]; bench-ci#538 stays open with it; PR #2585 has 9 red rows | [r brief2579] |
| #2570 | maint | harness diagnostics before a destructive safety restore; R13 | nothing in the product | [r comment] |
| #2557 #2471 | maint | R3: no product change; test-side floor fix (PR #2614); #2615's `db-sync-mode=safe` unobserved (job 944: all M10 rows PASS) | nothing observed | [r report §4.17, §6] |
| #2553 | maint | closes with #2503 (#2363) | nothing separate | [r report §7] |
| #2326 | maint / close | harness bug (podman `StartedAt` format; PR #2612); never an app bug | nothing | [r report §6] |
| #2333 | maint | bench fixture row; the 09-22 row-scoped rule keeps it from failing #1651 | that rule must hold through the cut, or PR #2368 lands (jobs 930/932 both cosign) | [r body; report §4.25] |
| #2057 #1997 #2473 #2001 | 2.0.x — as its gate | the `--image-upgrade` gate (PR #2180, RETURN r2) proves chain data + secrets survive an image update; 2.0.0 is the *first* appliance image (CHANGELOG:151-153), nothing upgrades *to* it; the gate's first customer is 2.0.1. #2473 has no pithead fix (bench-ci#408). #2001's restore proof is #2230's kvm leg [i] | the first OS update is proven by the KVM `update` phase and the manual battery M7–M9, not the chain-continuity gate. R2 (flip a KVM bench) still worth doing now | [r brief-1997, 2473-brief, comment2057] |
| #2454 | 2.0.x or close | outside-authored; runner cannot touch it. DIY 1.90, `.tari` on `/mnt`, wallet log dir permission denied | DIY hosts with relocated data keep the wallet error; the appliance chowns its bind mounts (architecture.md:163-165); health side is #2498/#2497 | [r #2454] |
| #1959 #2367 | 2.1 | PR #2305 (security review clean, verifier PASS, tier4-e2e) needs only an `agent/1959-…` takeover re-push (R14); after it only `bot_token`, `chat_id`, `healthchecks.ping_url`, `dashboard.auth.password` stay host-only | on an appliance, payout addresses, XvB endpoint, Telegram token, Healthchecks URL and the password are changeable only by configuration stick. **Counter-argument:** the 09-19 ruling "every field editable, never refused" reads as a 2.0.0 requirement and #2305 is one takeover from landing | [r 1959-comment; CHANGELOG; memory dashboard-edits-everything] |
| #2363 | 2.0.x | shell `apply` restarts the control runner with no drain; release images have no `ssh.*`, so DIY-only [i] | a shell `apply` during a dashboard request drops its result; PR #2503 is one kvm rerun from landing — moving it parks the PR | [r 2363-brief] |
| #2351 | 2.1 | dual-stack LAN name refused (`wizard_node_probe.py:96-100`); PR #2419 unreviewed by any job; hardware-blocked (bench-ci#371) | the user types the IPv4 | [r 2351-brief] |
| #1271 | 2.0.x | remote-mode render leaves Monero's RPC endpoint out of `.env`; PR #2140 conflicts at `tests/integration/lib.sh:377-378`, needs matrix e2e | no user-visible symptom named | [r report §4.23] |

Checkable consequence: after the MOVEs every remaining `v2 - appliance` issue is on #2602's list, a `release-blocker`, or a security/data-safety/fork fix with an open PR — except #2636 and #2589 (no PR) and #2464 (branch, no PR).

### 3.2 The road after GA — three horizons

**2.0.x — the first weeks.** Goal: a fresh appliance and an upgraded DIY host get through their first OS update, first restore and first Tari stall without a shell and without losing data.

| Belongs | Why here |
|---|---|
| Moved from the cut: #2627, #2610, #2606, #2599, #2595, #2579, #2363 (+#2553), #2454, #1271 | user-visible on day one, none data-destroying |
| #2057, #1997, #2473, #2001 | the gate that ends the horizon (below) |
| #2508 acceptance (`tari-observe`; bench-ci#584, ruling bench-ci#582) | the fix ships in 2.0.0; the measurement needs the tier on the bench holding the seeded chain (tiers.md:52,120) |
| Already post-GA, hit by a fresh box: #2436 (boot gate console silent ~16 min, P1), #2462 (serial-getty loop), #2463 (cert never covers IPv6 acquired after mint — permanent doctor FAIL on every KVM guest), #2461 | [r titles, `v2.x - post-GA`] |
| Prod's own findings once it takes 2.0.0: #2458 (Tor guard self-heal restarts tor+monerod without changing guards), #2459 (13,320 failed onion lookups/24 h), #2349 (per-worker tokens), #2465 (postmortem), #2498/#2497 (wallet health is `ps`) | [r memory prod-review; titles] |
| #2480 (a new Tari release never becomes work) — pull from `maintenance & gates` | the pre-release pin makes this a 2.0.x hazard (§3.3) |
| #1837 (appliance rigs have no OS-update path), #2373 (webhooks sentinel restore, `security`, blocked) | first-update and first-restore surface |
| Throughput follow-ups: second e2e bench with local pruned chains (devops, no issue); diff-class phase selection in the runner prompts (no issue); bench-ci#588/#595, #562, #560/#565, #371, #389, #578; runner `in_flight()` fixes and remote session hosts once the login token is on the benches (no issue) | [r report §3; §2.1–2.2 above] |

Gate that ends 2.0.x [i, proposed]: 2.0.1 ships only through a green `image-upgrade` phase on a KVM bench advertising `image_upgrade_ready` (tiers.md:168-172; R2), and prod has taken 2.0.0 then 2.0.1 through the dashboard with chains and secrets intact.

**2.1 — the designed features.** Goal: everything the host shell can do, the dashboard can do — gated and audited — and a remote node is first-class by name.

| Belongs | State |
|---|---|
| #1959 (PR #2305), #2367 (PR #2428) — every field editable, sensitive ones behind typed `APPLY` | PR-complete; takeover re-push + tier4-e2e rerun |
| #2351 (PR #2419) — remote node by LAN name | code done; bench-ci#371 fixture is hardware |
| #1999 via PR #2175 — multi-worker routing under load (with #1998, PR #2174 PASS r4 parked) | frozen lane today |
| #2508 findings beyond the transport fix: OFFLINE rate, time-to-sync-peer, lag recovery | needs bench-ci#584, then a `baseline_job` per tiers.md:98 |
| #2384 reboot/power-off from the dashboard (PR #2449), #2353 sync-page reasons in remote-Tari mode (PR #2422) | PRs open, parked |
| #1897 remote Monero RPC auth, #2483 backup Monero nodes, #2489 RPC-SSL pinning, #2482 `extra_flags`, #1805 stable doctor ids | designed, no PR |
| #911/#912 out-of-band approval, #786 appliance parity tracker, #1319/#2437/#2438 onion stratum | trackers |

Gate that ends 2.1 [i, proposed]: #786's inventory closes — every `config.reference.json` leaf has a dashboard route or a written host-only reason; remote-node-by-name passes on a bench with a reserved name; one `tari-observe` window beats the 6.0.0 baseline tenfold.

**Sovereign UI — post-2.0.** Goal: rebuild the dashboard and wizard on the Sovereign direction (36 screens, #2478) without losing a field, a gate, or the WCAG 2.2 AA pass (#1875). Belongs: #2478 tracker and #2512–#2547 (tokens → navigation → each view → #2547 coverage/accessibility/migration); data contracts first: #2499, #2479, #2491/#2492, #2475/#2477; standing UI defects the rebuild absorbs: #2466, #1872, #1863, #1866, #1899, #940. Gate: #2547, with every 2.1 editability route carried unchanged. This milestone and `v2.x - post-GA` are `exclude_milestones` [r README:219-221]; the runner pins from them only after the GA lane empties.

### 3.3 Risks that outlive the release

| Risk | What it is | Mitigation today | What 2.0.0 does not close | Owner |
|---|---|---|---|---|
| **Tor connectivity** #2508 | 6.0.0's `tor` transport dials onions only; even 5.3.1's dial set was ~98 % onions (2,042 onion vs 36 IPv4 in one hour [r #2508]). Node OFFLINE most of the day; a stall recovers by luck. | PR #2611 (`tor_tcp`) restores the 5.3.1 dial set, SOCKS still mandatory. Clearnet sync is first-sync only (`entrypoint.sh:56-67`). `tari-observe` exists, not applied (bench-ci#584). #2458's self-heal is monerod's, not Tari's. | Peer-list quality is upstream's; the fix returns to 1.20.0's level. No number until `tari-observe` runs; #2464 is the only detector and is drop-first. | fix: runner; tier: owner |
| **Egress firewall** #855 / #2460 | Podman never traverses `DOCKER-USER`, so the DROP was orphaned (fail-open, doctor said enforced). DIY: rules exist only on `up`/`apply`/`upgrade`/`reset-dashboard`; a reboot drops them while containers restart. | Appliance: `inet pithead_egress` nft table at forward priority −5 (#857; `02-tor-egress.sh:14-20`), engine pinned (#2091), six verifier verdicts (`:307-316`). DIY: PR #2601 boot unit, unmerged; prod open since 09-02. | #855 stays proof-only until the tier4-kvm provision leg runs on the frozen SHA. The dashboard reads firewall state from config (#2599), so any *other* loss shows green; `doctor` is the honest source. A netavark upgrade changing hook priorities is unmeasured [i]. | proof: #1651 run; #2599: 2.0.x or C10 |
| **Migration on real disks** #2636 | JMT writes a new DB beside the old: 161 → 216 GB peak; a full volume fails mid-migration; 5.3.1 cannot reopen the result. | CHANGELOG tells the user to have space, not interrupt, and back up first. #2621 unmerged (RETURN r1). Precheck pattern exists (`48-os-update-verbs.sh:134-142`) but not on the Tari path. OS rollback never touches the data partition (appliance.md:416-417), so it cannot undo a half-migrated DB. | The first real-disk migration in the field is prod's, with a DB that may be past 350,000 (→ #2618 rewind first). #1129 row 17 (commit-before-migration) unticked; #2588's V10 row moved. Duration measured on benches only. | precheck: runner (#2636); prod cutover: owner |
| **Upstream pre-release pin** | develop pins `v6.0.1-pre.0-mainnet` by index digest because 6.0.0 rejects canonical 350,008 (stored target difficulty, tari#8046 merged 09-22). 2.0.0 ships a Tari pre-release. | Digest pins, never bare tags [r #1129:29-31]. #2624/#2630 keep Compose and Quadlet pins equal. | When 6.0.1 final lands the re-pin is an image change: before GA it restarts the soak (R17); after GA it is a 2.0.x release. #2480 (frozen) says a new Tari release never becomes work — nothing will *tell* anyone. If final differs from pre.0 in a consensus rule, 2.0.0 nodes fork again; only #2464 would notice. | pull #2480 into 2.0.x; owner rules the re-pin |

Cross-cutting [r memory tier-follows-the-path]: every item that changes what runs on a box needs its tier-4 job on the PR head. The KVM registry race that killed five jobs today is closed (bench-ci#568 → PR #593); the remaining drag on landing the KEEP list is e2e queue depth (§2.1) and the six CONFLICTING rebases (§1.3).

## 4. Rulings needed now (defaults from report §6, deduplicated)

| # | Ruling | Default | Where it bites |
|---|---|---|---|
| R1 | existing PR vs fresh implementation | always resume, never fork | every CONFLICTING row in §1.3 |
| R2 | flip a KVM bench to `image_upgrade_ready=true` | yes, now | P4; #1651, #2057, #1997, #2473 |
| R3 | monerod `db-sync-mode=safe` | no product change | #2557, #2471 |
| R7 | start #2606 before #2464's PR | no | §3.1 |
| R8 / R9 | #2636 filed; #2618 on #2602's list | yes / yes | C4, C5 |
| R10 / R11 | V5 image source; isolated network | registry tag first; yes | #2589 — or accept the mainnet leg instead [i] |
| R14 | #2428 with #2305 | separate | 2.1 |
| R15 | merge bench-ci#565 under the no-CI-gate ruling | yes | P4's error text |
| R16 | bench-ci#560/#540/#541 → `v2 - appliance` | yes | freeze deadlock, #1651 |
| R17 | #1652 soak transfer | file-level delta at cut; re-soak on any image change | §1.4 step 5 |
| new | C10 (#2599), C14 (#2508 measurement), C15 (#2230/#2001), C16 (#2630), #1959: ship or move | C10 ship if #2601 lands cleanly; C14 fix ships, measurement moves; C15 ships if #2622's e2e is green by the freeze; C16 ship (rides C6); #1959 move unless the 09-19 ruling is meant for 2.0.0 | P2 |
| new | #2593 milestone | `v2 - appliance` | C3 |
| new | merge queue on develop or drop "require up to date" | one of the two | 20 refusals vs 53 merges today |
