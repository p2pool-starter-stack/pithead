# 2.0.0 backlog triage — wave 2 (2026-09-24)

Companion to [release-2.0.0-plan.md](release-2.0.0-plan.md). 173 open issues across pithead, rigforge and bench-ci were briefed by an investigator, adversarially verified by a second agent, and the 166 briefs that held were posted on their issues. This is the synthesis. **Applied by the operator on 2026-09-24 (owner-authorized milestone triage):** the CLOSE verdicts with merged-PR or on-develop evidence were closed (pithead #2457 #2321 #1897 #1866 #1886 #911 #2330; bench-ci #584 #540); moved INTO `v2 - appliance`: pithead #2593 #2575 #2470 #2407 #2379, bench-ci #556; moved OUT: #2633 → v2.x, #2632 #2631 → maintenance & gates, #2466 #2384 #2499 → v2.x (from Sovereign), #2476 → Sovereign. Left for the owner: the roadmap trackers #940 #1875 #797 #786 (verdict done/duplicate) and #1998 (closes with PR #2174), #2474 (confirm with #2057).


Input: 173 verified briefs (pithead 145, rigforge 14, bench-ci 14). Two briefs were void (pithead#2605, pithead#2532: the verifier aborted on a conflicting task) — re-run before acting on either.
Milestones that exist: `v2 - appliance` (GA), `v2.x - post-GA`, `maintenance & gates`, `Sovereign UI — post-2.0`. No `2.0.x`/`2.1` milestone exists; below, "2.0.x" = first weeks post-GA inside `v2.x - post-GA` or `maintenance & gates`, "2.1" = designed features needing a home (ruling R1).
Claims: (read) = file:line / PR / job cited by the brief; (inf) = inferred.

## 1. CLOSE candidates

### pithead
| issue | verdict | reason | evidence |
|---|---|---|---|
| #2457 | done | pipefail/on_bench stub fix merged, regression guard cites the issue | PR #2434 merged 09-20; detached-harness.sh:56-73 on develop 296c860e (read) |
| #1998 | done | XvB routing smoke implemented, 4 review rounds, bench-proven at PR head | tier4-kvm job 734; PR #2174 mergeable, CI green (read). Merge #2174; waive half of AC line 4 (R8) |
| #2321 | done | actuator "bug" was three leg-side bugs in the unmerged KVM leg; product untouched | jobs 629/641/662; algo_service.py + storage_service.py unchanged on develop (read) |
| #1897 | done | monero.remote credentials already wired through p2pool, doctor, wizard, redaction | #1898/#1920 merged (read) |
| #1866 | done | ssh.* removed from setup entirely, stronger than the hide asked for | PR #2285 merged 09-17; config.reference.json has no ssh key (read) |
| #1886 | done | every ledger row closed; gap 3 merged | PR #1926 on develop (read); re-file gaps 1/4/5 if untracked |
| #1875 | done | the design review is delivered; work lives in ~28 child issues | issue body/comments (read) |
| #940 | duplicate | answered by #1875 and its 16 spin-offs; tracker with no code of its own | #1875 title "(answers #940)" (read) |
| #911 | duplicate | superseded: #2076 removed the gate it specified | CHANGELOG Unreleased > Removed (read) |
| #797 | done | R0–R4 shipped in the 2.0.0 CHANGELOG; only R5 fleet polish left | CHANGELOG (read); file R5 as its own issue |
| #786 | done | A+B+D+F shipped; C/E are #911/#912 | decision record on the issue (read) |
| #2330 | superseded | the failing assertion no longer runs; band-aid deleted with it; root cause never found | commits 44ac082b, fff4641 (read). Close to #2444 with "cause unknown" |
| #2474 | not needed (conf 0.85, verifier overrode brief) | no code change left to schedule; consumer #2057/#2180 still open | (inf) — confirm with #2057 before closing |

### rigforge
None.

### bench-ci
| issue | verdict | reason | evidence |
|---|---|---|---|
| #588 | already closed | PR #595 merged to main 7fac920 09-24T00:02Z | (read) — process note: merged without a tier4-e2e run on the head |
| #584 | done | tari-observe now provisioned on the primary at the cited commit; 422 no longer reproduces | live capabilities (read); optional message fix is a separate 10-line PR |
| #540 | done | investigated in-thread, no runner defect, symptom did not recur; #2585 got its proof (job 970) | (read); clear `operator-action` |

## 2. KEEP-2.0.0 — not yet in `v2 - appliance`

| issue | now | why the release is wrong without it | state |
|---|---|---|---|
| pithead#2593 | none | every 5.3.1→6.0.0 upgrade crash-loops ~90 min on a mainnet DB with all health green (MDB_MAP_FULL); this IS the fork migration 2.0.0 ships | PR #2621 done, CI green, CONFLICTING → rebase, un-draft, tier4-e2e job 962 (read) |
| pithead#2575 | none | rollup of the red tier4-e2e matrix (p2pool restart cascade #2562, safety-rollback secret drift #2579); shipping = shipping a known-red gate | PR #2609 green, PR #2585 CI-red; add to v2-appliance (R12) |
| pithead#2470 | m&g | 1002b pools-write leg self-skips forever on any rig with a pools record → gate evidence for Worker Inspect silently absent | ~4-line fix; 09-19 ruling said v2-appliance, milestone never moved (R2) |
| pithead#2407 | m&g | rigforge-control pools leg asserts sync "applied" vs async "accepted" → reports a working path as broken | reuse existing helper; same 09-19 ruling, never applied (R2) |
| pithead#2379 | v2.x | uninstall keeps a Tari wallet volume whose only password it deletes, leaves a 0600 view-key file behind; issue body ties it to "what a 2.0.0 verb promises" | PR #2432 near-complete but has a demonstrated regression; not "ready" (read) |
| bench-ci#556 | none | fleet Tari baseline → 6.0.0; until every bench converges the fleet cannot produce the tier4-e2e evidence 2.0.0 needs | devops execution in flight (primary jobs 914/923, canary migrating); no PR (read) |
| pithead#394 | v2.x | the GA gate ledger itself; closes when GA ships | tracker; milestone hygiene only (R17) |

Already in v2-appliance, confirmed KEEP: #2636 (free-space precheck, R9), #2630 (caddy digest pin, R10), #1854 (restore secrets on ESP; PR #2394, block on #2626 per R13).
Flagged but NOT recommended for 2.0.0: #2453 (verifier said v2-appliance pending ruling; a 180→300 s budget bump in a fault leg — R2), #2343/#2344 (uninstall / rotate-secrets tier-4 proof; security-adjacent but DIY-only / already-shipped verbs — R14).

## 3. MOVE recommendations

### Actual milestone changes
- **2.0.x** pithead#2633 dashboard pytest sleeps: v2-appliance → v2.x post-GA (pure CI speed; R23)
- **2.0.x** pithead#2632 lint-sh xargs -P: v2-appliance → m&g (R23)
- **2.0.x** pithead#2631 shard run.sh: v2-appliance → m&g (9 min/PR, #2048 deferred it once; R23)
- **2.0.x** pithead#2466 workers probed 30 days: Sovereign → v2.x post-GA (bugfix in the poll loop, not redesign)
- **2.0.x** pithead#2384 reboot/poweroff: Sovereign → v2.x post-GA (PR #2449 code-complete, tier4-kvm proven; one e2e rerun)
- **2.0.x** pithead#2499 monerod "at tip, with peers": Sovereign → v2.x post-GA (diagnostics, milestone text names it; ruling)
- **2.0.x** pithead#1872 Tari-gauge gating half: split out of Sovereign → v2.x post-GA; formatting/ETA half stays (R7)
- **2.0.x** pithead#2575 → v2-appliance (see §2); pithead#2593, bench-ci#556 → v2-appliance
- **sovereign-ui** pithead#2476 Pithead-wallet donation: v2.x → Sovereign (its UI lives in #2475/#2477; mechanism undecided)
- **2.1** (needs a home, R1): pithead#2494 full-validation (behind #2437), #2490 multi-chain merge-mine (no second mainnet chain), #2483 backup Monero nodes, #2482 extra_flags, #2487 peer controls (half blocked on #2491), #912 fleet descriptor editing (mechanism dead since #2076), #1837 rig OS-update path (split the version-visibility half to 2.0.x); rigforge#528 solo mining, #533 stress/bench-verify (split), #531 thread placement (blocked #526); bench-ci#558 reboot-capable DIY KVM guest

### Confirm in place (no-op; verifier corrected "MOVE" labels to "stay")
- **2.0.x / v2.x post-GA**: pithead#2498 #2497 #2495 #2493 #2489 #2488 #2486 #2485(split, R7) #2484 #2481 #2465 #2463 #2462 #2461 #2459 #2458 #2439 #2438 #2437 #2436 #2349 #2225 #2089 #2045 #1805 #1800 #1360 #1319 #1219 #1217 #979 #978(docs-and-close is the cheapest exit); rigforge#534 #532 #530 #529 #527 #526 #520 #452 #445 #440; bench-ci#227
- **maintenance & gates**: pithead#2619(PR #2622) #2608 #2603 #2590 #2560 #2511 #2510 #2502 #2480 #2469 #2447 #2444 #2443 #2402 #2374 #2346(PR #2380) #2345(PR #2377) #2344(PR #2376) #2343(PR #2378) #2253(PR #2174) #2173 #2169(PR #2307) #2000(PR #2442) #1999(PR #2175) #1802(PR #2160) #1353(PR #2136) #1812 #1420; rigforge#499; bench-ci#585 #578 #562 #560(PR #565) #553 #548 #534 #505(needs re-diagnosis)
- **Sovereign UI**: pithead#2547–#2512 (36 children; #2532 brief void), #2492 #2491 #2479 #2478 #2477 #2475 #2353(PR #2422, hold on #2333) #1899 #1863
- **Blocked, no action**: pithead#2373 (code doesn't exist until PR #2305 merges)

## 4. Rulings needed (deduplicated) — recommended default

| # | ruling | default |
|---|---|---|
| R1 | No `2.1` milestone exists; 11 issues (§3) are designed features, not fast-follows | Don't create one pre-GA; label them `designed` inside v2.x post-GA; owner creates `v2.1` at GA if wanted |
| R2 | 09-19 "testing gaps that falsify the gate go to v2-appliance" ruling was commented but never applied on #2470, #2407, #2443, #2453 | Apply to #2470/#2407 (they falsify the gate); leave #2443 (documented skip) and #2453 (timeout bump) in m&g |
| R3 | Evidence tier for fixes that change nothing on a box (test-only, dormant quadlet fixture, feed keys): #2510 #1217 #1219 #452 #560 #2540 #1899 | tier-1 sufficient when no box path changes; tier4-e2e when it does (#1899 upgrade orchestration → tier4-e2e) |
| R4 | 15 stale draft PRs: #2621 #2432 #2380 #2377 #2376 #2307 #2442 #2175 #2160 #2136 #2415 #2422 #2449 #2174 #2394 | Resume, never fork; rebase first, then one fresh tier4 job on the rebased head; none go to develop ahead of the job |
| R5 | Sovereign sequencing and pre-GA work | #2512 → #2513 → #2514 before any child; no code before GA; each child blocked on its stated deps; #2513 split nav vs draft-preservation; security-reviewer on the address-masking AC |
| R6 | #1802/#1353 blocked on closed #2197 (premature marker) | Re-target both to #2602 now so the runner does not resume under a live freeze |
| R7 | Split candidates: #2485 (log_level now / console later), #1872 (gate / ETA), #1837 (version visibility / delivery), #2497 (tier-3 rows only), #2491 (read-only verbs first), #2487 (flags+panel / console), rigforge#533 (verify / stress), #2458 (SOCKS isolation first), #2463 (message now / trigger later) | Split, all of them |
| R8 | #1998 AC line 4 half-met (fresh KVM guest never syncs); #2174 also "Closes #1998" | Waive explicitly, close #1998 on merge; also close #2321 as diagnosed |
| R9 | #2636 precheck: where, how much, order vs #2618 | At the HOLD_CHAIN release point; require free ≥ data.mdb + 10%; rewind (#2618) before the check; own PR, closes the #2602 checklist line |
| R10 | #2630 bundle with #2629? evidence? | Own PR after #2629 lands (same file); fresh tier4-kvm provision job |
| R11 | #2593 targeted tier4-e2e (key-acceptance + healthy) sufficient without a mainnet-DB bench mode? | Yes, per the recorded ruling; bench-ci#548 stays m&g |
| R12 | #2575 milestone; cosign failure in job 938 | v2-appliance; file cosign separately, don't block #2609 |
| R13 | #1854 / PR #2394 merge while #2626 (stale miner_released latch after restore) is open | Block merge — restore path that mines unsynced is what the gate exists to catch |
| R14 | #2343 (uninstall) / #2344 (rotate-secrets) tier-4 proof: pull into 2.0.0? | No — DIY-only / already-shipped verbs; land PRs #2378/#2376 first weeks post-GA; #2344 `.bak` sweep gets its own issue |
| R15 | Security postures: #2538 scope; #2349 WORKER_API_TOKENS read-only (escalated 09-22, unanswered); #1319/#2437 client-auth key; #912 second-identity approval | #2538 daemon RPC only, Tor-first; #2349 yes, read-only probe creds, host-only path for write tokens; one shared v3 key for v1; #912 no plan exists — owner call |
| R16 | #1812/#1420 parked lane (ship queue empty AND GRAND<1000M) | Still binding; verifier label "CLOSE-wontfix" on #1812 contradicts its own body — park, don't close |
| R17 | #394 stale checklist + wrong milestone | Honor the no-comment ruling; leave milestone |
| R18 | bench-ci#556: unattended fleet-wide continuation; close criterion | Proceed per 09-23 ruling; keep open until every bench clears all four boxes |
| R19 | #2465 tari_stale alert vs #2508 Tor starvation noise | Gate on sustained ≥10 min as the issue's own AC says |
| R20 | #2459 HSDir log budget belongs to bench-ci, not pithead | Re-file the measurement on bench-ci; accept churn as inherent |
| R21 | Void briefs #2605, #2532 | Re-run both before any action |
| R22 | bench-ci#585 who may cancel; #534 refused night; #578 cooldown | Same-submitter only, real auth later; retry same commit on next tick with a retry cap; 20 s cooldown |
| R23 | CI-speed knobs: pytest-xdist (#2633), -P (#2632), shard mechanism (#2631) | Add xdist test-only with `-n auto`; cap -P at nproc; strategy.matrix |
| R24 | #2384 merge sequencing with #2385's PR #2434 | Rebase #2434 onto sys-reboot after #2449 merges |
| R25 | #2373 | Stay blocked on PR #2305; do not pre-write against a churning branch |
| R26 | #2499 include auto-restart like Tari's? proceed before #2464 lands? | Visibility only, the 5 listed points; proceed independently |
| R27 | rigforge#526 needs `xmrig --dry-run` on the pinned version (unverified) | Confirm on a build bench; fall back to a jq structural check |
| R28 | #2453 budget value; #2511 timeout; #2590 apply wait to fault_unhealthy | 300 s (matches sibling); reuse 180 s; no |
| R29 | #2225/bench-ci#227 who builds the CoW chain root post-GA | devops role, the second bench, first weeks post-GA |

## 5. Ten issues most worth a worker after GA (ranked)

1. **pithead#2499 + #2464** monerod/Tari "at tip, with peers" — the nine-day-green-tick class (#2465) is revenue loss; #2464 code exists unmerged, #2499 is five listed points on an existing debounce.
2. **pithead#2458** Tor self-heal never changes guards — ~4 min mining gaps every 1–2 days on prod; SOCKS isolation alone (R7) likely removes most restarts.
3. **pithead#2384** reboot/poweroff — PR #2449 finished and KVM-proven; one tier4-e2e rerun, then merge. Closes a physical-power-cycle workaround.
4. **pithead#2436** silent 16-minute boot gate — reads as a hang and invites a power cut mid A/B rollback, the one thing the mechanism can't survive; small journal/console change.
5. **rigforge#526** xmrig overlay — foundation for eight sibling issues (#527–#534) and removes the #445 hand-edit-overwritten trap; ship alone first.
6. **pithead#2346 / #2345 / #2344** tier-4 for reset-dashboard, rotate-onion, rotate-secrets — three shipped destructive/security verbs with no bench proof; PRs #2380/#2377/#2376 are ~done, need rebase + one job each.
7. **pithead#2466** rigs probed and badged for 30 days — unbounded probing, log spam, misleading badge; reuse WORKER_FALLOFF_SEC, fix the restart-reset in the same PR.
8. **pithead#2633 + #2632 + #2631** as one CI sweep — ~10 min off every PR's wall clock (dashboard sleeps, lint-sh, run.sh shards); test-only, no box path.
9. **pithead#2000 + #1999** fault-injection over SSH and multi-worker load — PRs #2442/#2175 have green tier-4 evidence, blockers all closed; rebase + one run each, then #2173's ceilings follow.
10. **pithead#2480** a new Tari release never becomes work — fixes the mechanism that let the fork sit silent four months; touches only dependabot.yml and pin-watch.sh, no conflict with #1129's PRs.

Runners-up: rigforge#529 (2-line autosave/watch fix), pithead#2461 (permanent stratum WARN), #2489 (RPC-SSL pinning for remote nodes), #2437 (onion stratum, default off).
