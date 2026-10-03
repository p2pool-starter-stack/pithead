# Sovereign test coverage and remaining risks

This is an early, opt-in implementation of [#2478](https://github.com/p2pool-starter-stack/pithead/issues/2478).
It must not become a release default before 2.0.0 GA. Passing this branch's unit tests
does not close the 36-screen program or establish appliance readiness.

## What the tests prove

| Behavior | Evidence | Limit |
| --- | --- | --- |
| Classic default, opt-in selector, hash/query preservation and range validation | Frontend orchestration and route tests | Does not prove every existing bookmark or extension interaction |
| In-flight navigation cannot paint an obsolete chart response | Deferred-response regression tests, including browser Back | Superseded requests are ignored, not aborted; a hung request can delay the newest selection until the 25-second timeout |
| Offline refresh retains data and retry is connected | Existing polling tests plus the Sovereign browser check | A successful HTTP response can still contain stale upstream telemetry |
| Missing/partial metrics and attention destinations | Overview state matrix | Server completeness and freshness remain API contracts, not something the UI can infer |
| Worker summary bounds, optional mining features and control gating | Component tests using the state contract | No 50/100-worker performance acceptance or rollout capability implied |
| Draft retention, focus, explicit address reveal and teardown | `/checks?ui=sovereign` mounts actual components in a browser | Not automatically run in CI; Node's string renderer does not exercise DOM lifecycles |
| Wizard stages and destructive/credential controls survive the new frame | Wizard regression tests and synthetic stage preview | Local preview rejects writes; cannot prove disk erase, provisioning or reboot success |
| Fixture isolation | Loopback server tests for methods, paths, CSP and fixture selection | Synthetic service is not an authentication or production TLS test |

Run `make test-frontend`, `make test-dashboard`, `make test-patch-coverage` and the
repository-required `make test`. Keep actual exit statuses and full private logs.
Run `make test-container` on macOS when Docker is available. Do not bypass failed
Linux/toolchain checks or reduce coverage thresholds to obtain a green result.

## Known gaps before release

1. **Full feature acceptance remains open.** Existing earnings, settings, maintenance
   and diagnostics views have new homes but retain much of their current design.
   Fleet jobs, richer history, node sharing, settings organization and complete recovery
   flows are separate issues. Reconcile the 76 feature groups against current `develop`
   under #2547, not just the September mockups.
2. **Data freshness needs a stronger contract.** The UI detects request failures and shows
   the last snapshot. A healthy HTTP response does not prove fresh worker/node probes.
   Exercise delayed collectors, clock changes, partial responses, database recovery and
   stale-but-successful polls; require explicit freshness before adding stronger claims.
3. **Browser and accessibility acceptance is incomplete.** Repeat the native browser
   checks in supported Safari/Firefox/Chromium versions, then verify keyboard-only use,
   a real screen reader, Light/Auto/Dark, contrast, reduced motion, 200% reflow and long
   translated or operator-provided strings. Automate the browser checks through the
   existing browser tooling before making them a merge gate; no new browser dependency
   has been added to the appliance.
4. **Large-fleet and small-device performance is unmeasured.** Exercise 2/50/100 workers,
   long names, wide tables, large event histories and frequent updates on low-power
   hardware. Record load/interaction timing, memory and transferred bytes. Bundled module
   size alone is not a CPU/RAM measurement. The native table's phone usability remains #1863.
5. **Wizard appearance is ahead of its acceptance evidence.** The frame retains the
   single-page progressive form rather than claiming the full #2543–#2545 redesign.
   Verify fresh disk, existing-data keep/fresh/wipe, rig USB, restore, retry and one-time
   credentials at desktop and phone widths. Native labels and warnings must remain
   visible at the point of action. A future role-specific step flow needs a host-contract
   review so that a presentation step never becomes installation authority.
6. **Real image handoff requires reserved hardware.** No image is built or deployed by
   this preview. Before appliance promotion, run the affected `tests/os/` boot/install/
   recovery phases on the exact image/source checksum, including lost connections,
   rejection, shutdown/removal/reboot order and restored operator access. Follow the
   reserved-host protocol and retain sanitized evidence; source tests are insufficient.
7. **Merge and packaging need current-head proof.** The branch started before GA and
   `develop` will move. Reconcile changed API fields, wizard stages, static asset packaging
   and shared controls after updating the branch. Run required CI and independent review
   on that head. The classic path shares polling and controls, so keep its regressions
   in the test run even though Sovereign is opt-in.

## Where unexpected failures may emerge

These are discovery targets, not claimed defects or an exhaustive prediction:

- Long-lived tabs during updates: mixed cached assets, auth expiry, concurrent operator
  edits, schema changes and disconnected commits. Soak a tab across a controlled update
  and compare displayed state with the host's settled result.
- Browser/platform differences: native details/dialog behavior, focus after hidden
  sections, zoom, font metrics, color preferences and low-memory tab suspension. Test
  actual supported browsers and assistive technology rather than relying on screenshots.
- Unusual topology and hardware: remote nodes, slow Tor responses, missing collectors,
  unusual disk identifiers and interrupted restore media. Use bounded failure injection
  in existing fakes and the reserved appliance matrix when source tests cannot prove it.
- Product assumptions: an operator may read configured egress as observed privacy,
  recorded payouts as wallet balance, a worker identity as a physical machine, or an
  accepted request as completion. Observe a fresh operator completing setup and recovery;
  fix ambiguous wording and add regressions for each demonstrated misunderstanding.

When discovery reveals a new risk, record a reproducible case and link its owning issue.
Do not invent a backend rewrite or additional service before evidence identifies a need.
