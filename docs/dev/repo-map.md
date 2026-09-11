# Repo map

Find the feature first, then its matching tests. The root holds the product's
published entry points and conventional project files; implementation details live
under the directories below.

```text
pithead/
├── lib/pithead/           ordered source slices for the generated CLI
├── dashboard/
│   ├── mining_dashboard/ Python application and browser assets
│   └── tests/            Python and frontend tests, grouped like the source
├── os/                   bootable appliance, installer, and host services
├── build/                container build contexts for stack daemons
├── tests/
│   ├── stack/            CLI unit suites, grouped by feature
│   ├── integration/      live harness, selftests, fakes, and tools
│   └── os/               appliance harness and phase modules
├── scripts/
│   ├── lint/             repository gates and their selftests
│   ├── release/          release preparation, publication, and verification
│   └── watch/            scheduled dependency and security checks
├── docs/                 operator guides
│   ├── dev/              contributor guides and architecture contracts
│   ├── images/           documentation images
│   └── research/         historical studies and supporting records
└── .github/              CI, templates, and ownership
```

## Product entry points

| Area | Start here | Change and verify |
|---|---|---|
| CLI | `lib/pithead/`, `scripts/build-pithead.sh` | Edit slices; `make` builds the ignored root `pithead`. `make test-stack` tests it. |
| Dashboard | `dashboard/mining_dashboard/main.py`, `dashboard/README.md` | Python services and HTTP routes; `make test-dashboard`. |
| Browser UI | `dashboard/mining_dashboard/web/static/dashboard.js` | Feature modules and styles below; `make test-frontend`. |
| Compose | `docker-compose.yml`, `config.reference.json` | Runtime service graph and configuration contract; `make test-compose`. |
| Containers | `build/<daemon>/` | Dockerfiles, entrypoints, and healthchecks; CI builds the images. |
| Appliance | `os/README.md`, `os/build-image.sh` | Rootfs, RAUC slots, installer, and host services; `tests/os/run.sh`. |
| Release | `scripts/release/release.sh`, [release guide](releasing.md) | Stage, verify, promote, and publish; `make release ARGS="--dry-run"` previews the plan. |

The CLI is concatenated in `LC_ALL=C` filename order, keeping the distributed
executable self-contained. Do not nest or reorder `lib/pithead/` slices without
checking that contract. `make lint-pithead-build` checks assembly and ordering
guards. Sources are excluded from release bundles.

## Dashboard feature folders

Python code is rooted at `dashboard/mining_dashboard/`; its tests are rooted at
`dashboard/tests/`.

| Source | Responsibility | Tests |
|---|---|---|
| `client/` | Daemon and external-service clients | `tests/client/` |
| `config/` | Configuration parsing and validation | `tests/config/` |
| `service/` | Polling, persistence, and shared application orchestration | `tests/service/` |
| `service/health/` | Service health and diagnostics | `tests/service/health/` |
| `service/network/` | Network routing and egress | `tests/service/network/` |
| `service/notify/` | Alerts and notification channels | `tests/service/notify/` |
| `service/workers/` | Worker state and control | `tests/service/workers/` |
| `service/xvb/` | XvB switching, calculations, and outcomes | `tests/service/xvb/` |
| `web/views/` | HTTP views and response construction | `tests/web/views/` |
| `web/server.py` | HTTP application setup and route registration | `tests/web/` |
| `wizard/server.py`, `wizard/form.py` | Appliance wizard server, form translation, and install handoff | `tests/web/test_wizard*.py` |

Keep polling order, database locks, and transaction scopes intact when extracting
helpers. The storage mixins share `StateManager`'s connection and lock; the
atomicity and annotation tests in `tests/service/` check those boundaries.

`python -m mining_dashboard.wizard` remains the appliance's wizard launch command;
the package's `__main__.py` delegates to its server.

Browser assets live in `web/static/`. JavaScript feature folders are `app/`,
`config/`, `network/`, `system/`, `workers/`, `xvb/`, and `wizard/`.
`tests/frontend/` mirrors those folders. Its `harness.mjs`, `helpers/`, and
`fixtures/` provide shared test inputs and rendering support. Node discovers the
nested tests through `make test-frontend`.

`dashboard.css` imports the ordered files in `styles/`; wizard styles stay in
`wizard/`. `vendor/` contains third-party browser libraries and their provenance.
Keep local code out of `vendor/`.

## Shell suites and tools

| Directory | How it runs |
|---|---|
| `tests/stack/` | `run.sh` loads the shared harness and an explicit ordered list of feature suites. Missing or failed sources fail the run. |
| `tests/stack/{appliance,control,dashboard,doctor,lifecycle,release,secrets}/` | Feature assertions loaded by the stack runner; retain shared setup and cleanup order. |
| `tests/stack/standalone/` | Independent suites invoked by Make and CI, including Compose validation. |
| `tests/integration/lib/` | Sourced helpers and phase functions for `tests/integration/run.sh`. |
| `tests/integration/selftest/` | Pure harness checks; `make test-integration-selftest` also checks appliance module loading. |
| `tests/integration/tools/` | Explicitly invoked chain preparation and test-host inspection tools. |
| `tests/integration/fakes/`, `mini-stack/` | Fake-daemon contracts and containerized end-to-end checks. |
| `tests/os/lib/`, `phases/` | Shared appliance harness functions and ordered boot/install/update/fault phases. |
| `tests/os/appliance-*-leg.sh` | Self-contained assertion legs the phases call (hostname, diagnostics, config approval, Tor-egress enforcement). Each carries a `--self-test` driven from tier 1 by `tests/stack/test-harness-tooling.sh`, so its logic is provable without a KVM. |
| `tests/runner/` | The pinned Linux image `make test-container` runs the other tiers inside, so a macOS or Windows host reaches CI's verdict. Built and CVE-scanned by `test-images.yml`; reaches no user. |
| `scripts/lint/` | Gates invoked by `make lint`; selftests live beside the gate they exercise. |
| `scripts/watch/` | Scheduled checks invoked by `.github/workflows/`. |

The harness entry points retain their command-line interfaces. Live integration
and appliance runs require a reserved host; local selftests do not start a VM.
Use `scripts/sanitize-test-log.sh` for bounded build and serial-log excerpts, as
described in the [AI workflow](ai-workflow.md).

## What stays at the root

- Runtime contracts: generated `pithead`, `pithead-completion.bash`,
  `docker-compose.yml`, `config.*.json`, `cosign.pub`, and `VERSION`.
- The public bootstrap script, `install.sh`, whose URL is a published interface.
- GitHub and contributor entry points: `README.md`, `CONTRIBUTING.md`, `LICENSE`,
  `SECURITY.md`, and `CODE_OF_CONDUCT.md`.
- Shared agent guidance: `AI_RULES.md`, with relative symlinks from `AGENTS.md`,
  `CLAUDE.md`, and `.cursorrules`.
- Tool-discovered configuration such as `.editorconfig`, `ruff.toml`,
  `biome.json`, and `.pre-commit-config.yaml`.

Release bundles and appliance images use explicit file lists. Moving a source
file does not authorize adding development tools or private evidence to an image.

For test tiers and placement, read [testing strategy](testing-strategy.md) and
[testing guide](testing-guide.md). For configuration values, read
[configuration](../configuration.md). The wizard spool-file protocol is in
[appliance wizard](appliance-wizard.md#host-and-page-spool-files).
