# Sovereign implementation preview

An opt-in dashboard refresh on `codex/sovereign-ui`, based on `develop` at
`07a26be1c12d0d88a77571b71512533ad858a6ed`, for after 2.0.0 GA.

Tracks [the Sovereign program](https://github.com/p2pool-starter-stack/pithead/issues/2478),
starting with the visual foundation, navigation and overview in
[#2512](https://github.com/p2pool-starter-stack/pithead/issues/2512),
[#2513](https://github.com/p2pool-starter-stack/pithead/issues/2513) and
[#2515](https://github.com/p2pool-starter-stack/pithead/issues/2515).
This branch does not close the program or change release defaults.

## Run locally

From the repository root:

```sh
node dashboard/tests/frontend/fixtures/sovereign-preview.mjs
```

Open `http://127.0.0.1:8765/?ui=sovereign#overview`.
Set `PORT` to choose another local port. The server binds to loopback, serves synthetic
sample data and rejects all write requests. It does not start a stack or connect to miners.
The sample-data label stays in the footer.

On a dashboard built from this branch, append `?ui=sovereign#overview` to its URL to use
real telemetry with the existing authenticated API. The ordinary URL retains the classic UI.
Chart range and zoom parameters remain available with the preview selector.

## Implemented in this pass

- Warm charcoal and orange tokens, Light / Auto / Dark, system typography and a static SVG
  network illustration. All assets are local; no dependency or runtime was added.
- Sidebar and compact mobile navigation, hash routes with browser history, route focus,
  snapshot status and retry after a failed poll.
- Overview, a bounded worker summary, available recorded payout totals and attention links
  derived from the current state contract.
- Worker search, attention filter, address reveal, sortable worker details and the existing
  inspection/control flow. Worker identities remain distinct from physical machines.
- Dedicated homes for existing earnings, XvB/energy calculators, network details, activity,
  configuration, backup and diagnostics. Expert fields and host confirmation gates remain.
- Configuration drafts stay mounted across local page navigation; reload/close uses the
  native unsaved-changes prompt. Drafts and secrets are not persisted to browser storage.

## Boundaries and remaining work

The current Preact/HTM modules and Python service already support this visual direction.
Keeping them avoids a second runtime, client build pipeline, API migration and duplicated
mining-control logic. Reconsider a backend change only against measured resource use.

The issue program also includes durable fleet selection/jobs, richer worker capabilities,
payout history/completeness, power-source coverage, node sharing, reorganized settings,
setup/recovery and final accessibility/migration acceptance. Those contracts and full screen
redesigns remain open. Existing tools are reused here; their placement is not a claim that
each corresponding Sovereign issue is complete. Configured routes are not observed traffic.

The preview has no new deployment, daemon, migration, scheduled task or live bench action.
Merge and release remain after GA and require the repository's normal independent review
and checks. This local visual pass is not live-stack or appliance evidence.

## Checks

Run `make test-frontend`, `make test-dashboard`, then `make test-patch-coverage`.
Use `make lint-js lint-file-budget` for the touched frontend surfaces.
The complete `make test` gate requires the documented Linux toolchain; on macOS use
`make test-container` with a running Docker daemon.

Frontend checks include routing, status distinctions, retained snapshots, control gating,
bounded activity and the preview server's read-only/path boundary. Browser review covers
desktop and phone layouts, both palettes, navigation and worker filtering.
