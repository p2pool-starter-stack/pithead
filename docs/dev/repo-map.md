# Repo map

Find the feature first, then its matching tests. The root holds the product's
published entry points and conventional project files; implementation details live
under the directories below.

```text
pithead/
├── lib/pithead/           ordered source slices for the generated CLI
├── go/                    incremental Go commands and feature packages
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
├── .config/              tool-discovered configs each linter is pointed at explicitly
├── docs/                 operator guides
│   ├── dev/              contributor guides and architecture contracts
│   ├── images/           documentation images
│   └── research/         historical studies and supporting records
└── .github/              CI, templates, and ownership
```

The [project donation planner](project-donation-planner.md) defines the pure
cycle planner, simulator and provisional policy for the dark feature.

Configuration defaults live in `dashboard/mining_dashboard/config/defaults.json`.
`scripts/build-config-defaults.py` exports the embedded CLI table in
`lib/pithead/19a-config-defaults.sh`, the legacy-compatible `config.reference.json`, and
DIY/appliance starter configs (`config.minimal.json`, `config.minimal.appliance.json`).
`dashboard/mining_dashboard/config/defaults.py` reads the same table for the dashboard and wizards.

Host-resource availability and the existing disk-history capacity estimate are computed in
`dashboard/mining_dashboard/service/host_resources.py`; the collector metadata stays in
`dashboard/mining_dashboard/collector/system.py`. Their unit tests live in the matching
`dashboard/tests/service/` and `dashboard/tests/collector/` folders.

## Product entry points

| Area | Start here | Change and verify |
|---|---|---|
| CLI | `lib/pithead/`, `scripts/build-pithead.sh` | Edit slices; `make` builds the ignored root `pithead`. `make test-stack` tests it. |
| Go port | `go/cmd/pithead/`, `go/internal/`, [parity ledger](go-port/PARITY.md) | `make go-build`, `make test-go-parity`; `tests/go-parity/` holds adapters for unchanged reference suites. |
| Dashboard | `dashboard/mining_dashboard/main.py`, `dashboard/README.md` | Python services and HTTP routes; `make test-dashboard`. |
| Browser UI | `dashboard/mining_dashboard/web/static/dashboard.js` | Feature modules and styles below; `make test-frontend`. |
| Compose | `docker-compose.yml`, `config.reference.json` | Runtime service graph and configuration contract; `make test-compose`. |
| Containers | `build/<daemon>/` | Dockerfiles, entrypoints, healthchecks, and Monero's bounded archive downloader; CI builds the images, and `make test-tools` checks download recovery. |
| Appliance | `os/README.md`, `os/build-image.sh` | Rootfs, RAUC slots, installer, and host services; `tests/os/run.sh`. Quadlet golden units share `os/quadlet/common/`; `tests/stack/test-render-quadlet.sh` checks complete profile inventories and byte parity. `os/rootfs/fetch-go-source.sh` bounds pinned Go-source fetches; `tests/os/selftest-go-source-fetch.sh` runs its local Git transport regression. |
| Release | `scripts/release/release.sh`, [release guide](releasing.md) | Stage, verify, promote, and publish; `make release ARGS="--draft --dry-run"` previews the plan. |
| Manual QA | [Start here](manual-qa/README.md), `docs/dev/manual-qa/` | DIY, appliance and release guides retain the checklist step IDs; `broken-configs.tsv` and `tests/stack/test-manual-qa-oracle.sh` replay the documented dry-run refusals in shell block 5. The start page holds the run sheet, result rules and glossary. |

The native Go status path lives in `go/internal/status/`.
`make test-go-status-parity` compares it with the Bash reference using the
synthetic executables in `tests/go-parity/`.
Go doctor JSON reporting lives in `go/internal/doctor/`; probe collection still
uses Bash. `make test-go-doctor-parity` compares reports using synthetic probes
and the unchanged Bash formatter.
Native memory and clock probes are in `go/internal/doctor/memory.go` and
`go/internal/doctor/clock.go`. `make test-go-doctor-memory-parity` compares them with the
Bash reference. Doctor's CLI collector still uses Bash.
Engine selection is shared by native status and doctor in `go/internal/host/`.
`make test-go-doctor-host-parity` compares boot persistence, CPU and dependency
probes with the Bash reference using synthetic tools.
`go/internal/doctor/release.go` and `go/internal/doctor/daemon.go` implement
verifier and engine availability findings. `make test-go-doctor-verification-parity` compares their
output and engine calls against the unchanged Bash checks using fake tools.
Control-unit ownership and local-miner HugePages findings are in
`go/internal/doctor/control.go` and `go/internal/doctor/local_miner.go`.
`make test-go-doctor-control-parity` compares them with Bash against synthetic
installs and unit files; systemctl is discovered without being executed.
`go/internal/doctor/disk.go` implements the grouped disk check shared by doctor
and setup preflight. `make test-go-doctor-disk-parity` compares budgets, ancestor
resolution, filesystem grouping and findings with Bash using fake df responses.
`go/internal/doctor/data_directories.go` and `deployment.go` implement missing-data
and setup-state findings. `make test-go-doctor-data-parity` compares them and the
relocated-install warnings with Bash using disposable files and getter outputs.
`go/internal/onion/` shares dashboard address formatting between status and doctor.
`go/internal/doctor/onion_addresses.go` implements the Tor address report;
`make test-go-doctor-onion-parity` compares it with Bash using getter outputs.
`go/internal/address/` implements Monero and Tari payout-address classification,
checksums and public-key extraction. `go/internal/doctor/config.go` implements the
config diagnostics; `make test-go-doctor-config-parity` compares both with Bash
using public vectors and supplied config getter outputs.
`go/internal/host/public_ip.go` implements the legacy public-interface classifier.
Doctor's stratum exposure, listening and Tor runtime probes live in
`go/internal/doctor/stratum_exposure.go` and `network_runtime.go`.
`make test-go-doctor-network-parity` compares findings and tool arguments with
Bash using fake `ip`, `ss`, `docker` and `curl` commands.
`go/internal/firewall/` implements LAN firewall rule readback;
`go/internal/doctor/lan_guard.go` and `lan_guard_hold.go` implement LAN access
reports and boot-hold diagnostics. `make test-go-doctor-lan-parity` compares
readback, reports and tool arguments with Bash using fake firewall and host tools.
`go/internal/firewall/egress*.go` implements Docker and nft Tor egress readback,
token and CIDR checks, and sync-rule validation with supplied config/state values.
`go/internal/doctor/egress_firewall.go` implements its doctor report;
`make test-go-doctor-egress-parity` compares helpers, readback and messages with
Bash using isolated tools. `go/internal/firewall/tor_sync_state.go` selects sync
exceptions from supplied getters and marker metadata; config/state-dir readers
and collector wiring remain Bash. `make test-go-doctor-nft-parity` compares nft
readback, doctor output and sync-state selection against Bash.
`go/internal/torhistory/` plans canonical outage-record transitions and validates
heal evidence. `go/internal/doctor/tor_history.go` checks saturation, current Tor
egress and the circuit-history finding. `make test-go-doctor-history-parity`
compares these with Bash; mount discovery, locks, writes and recovery stay Bash.
`go/internal/doctor/container_restarts.go` observes restart snapshots and reports
crash loops; `revenue.go` reports chain/miner readiness with a supplied migration
hold. `make test-go-doctor-containers-parity` compares findings and command order
with Bash using fake engines and sleep. Collector and hold discovery remain Bash.
`go/internal/doctor/monero.go` implements Monero sync, peer-count and tip-age
findings with supplied RPC getters and time. `make test-go-doctor-monero-parity`
compares findings, authentication arguments and probe order with fake tools;
the collector and config/time readers remain Bash.
`go/internal/nodeprobe/monero.go` implements remote Monero RPC preflight with
supplied endpoint/login/cap values. `make test-go-node-monero-parity` compares
reasons, arguments and stdin config bytes against Bash using fake tools;
config readers, address policy and ZMTP orchestration remain Bash.
`go/internal/nodeprobe/zmq.go` validates ZMTP greetings and publisher READY frames
and classifies supplied handshake replies/statuses. `make test-go-node-zmq-parity`
compares these with Bash through a fake timeout.
`go/internal/nodeprobe/zmq_exchange.go` implements stream I/O over
an already-open connection and supplied absolute deadline.
`make test-go-node-zmq-exchange-parity` compares wire bytes, framing and timeout
results with Bash over inherited local descriptors; on macOS it uses GNU head.
Dialing, endpoint orchestration and production callers stay Bash.

The standalone [Monero LMDB tools](lmdb-tools.md) artifact is built by
`scripts/tools/build-lmdb.py` and `.github/workflows/lmdb-tools.yml`.
`tests/tools/test_lmdb_build.py` checks extraction and provenance inputs;
`tests/tools/prove-lmdb.py` and `tests/tools/lmdb-fixture.c` prove disposable
concurrent-writer copies in CI. These tools do not change the runtime image.

Native raw config parsing and duplicate/placeholder validation live in
`go/internal/config/document.go`. `make test-go-config-document-parity` compares
exact diagnostics and runs the unchanged raw-parser suite through the selected
gate. The CLI's Bash fallback carries an internal Go-binary marker; unsupported
JSON retains the embedded Python parser. `go/internal/config/defaults.go` and
`jq_json.go` implement defaults, materialization and getters with ordered jq-style
output. `make test-go-config-defaults-parity` checks runtime tables, exact bytes,
compatibility fallback and the unchanged v2.0.0 render fixture/goldens.
`go/internal/config/validation.go` implements worker, energy, webhook and
control-character validation through the same internal binary marker.
`make test-go-config-validation-parity` compares diagnostic bytes/status and
proves native selection without jq. Unsupported inputs keep the original
validators. `go/internal/config/stratum.go` parses and validates stratum bind/port
settings through `lib/pithead/27b-stratum-endpoint.sh`, retaining Bash fallback.
`make test-go-stratum-parity` compares diagnostics, partial state and helper frames.
`go/internal/config/network_settings.go` derives/validates network, remote and pool
settings through `lib/pithead/27d-go-network-settings.sh`;
`make test-go-network-settings-parity` checks verdict order and partial globals.
`go/internal/config/proxy_settings.go` parses explicit stratum passwords, TLS and
donation settings through `lib/pithead/27e-go-proxy-settings.sh`;
`make test-go-proxy-settings-parity` checks state, errors and auto-password fallback.
`go/internal/config/dashboard_access.go` parses dashboard host, port, flags and
timezone through `lib/pithead/27f-go-dashboard-access.sh`;
`make test-go-dashboard-access-parity` checks state, discovery order and traps.
Host-timezone discovery/default insertion stays in the original Bash caller.
`go/internal/config/dashboard_auth.go` parses credentials and validates auth/onion/control
policy through `lib/pithead/27g-go-dashboard-auth.sh`;
`make test-go-dashboard-auth-parity` checks verdicts and hash/warning order.
SHA-256, stable hash reconciliation, bcrypt and warning decisions stay in Bash.
`go/internal/config/directories.go` derives data paths and the shared data root via
`lib/pithead/27h-go-directories.sh`; `make test-go-directories-parity` compares
layouts, preserved spellings and original caller-side safety checks.
`go/internal/config/version.go` validates version policy and renders ordered config stamps through
`lib/pithead/27l-go-config-version.sh`; `make test-go-config-version-parity` compares
policy and files. VERSION reads, warnings and file transactions stay in Bash.
`go/internal/config/migrations.go` plans legacy worker/XvB and Telegram-control migrations through
`lib/pithead/27m-go-config-migrations.sh`; `make test-go-config-migrations-parity` compares
decisions, ordered file bytes and failure handling. Backups, callbacks and file transactions stay in Bash.
`go/internal/config/persistence.go` renders credential write-back and CLI appliance-default JSON via
`lib/pithead/27n-go-config-persistence.sh`; `make test-go-config-persistence-parity` compares
bytes, modes, provider calls and failures. Password generation and file transactions stay in Bash.
`go/internal/config/masked.go` masks dashboard prefill JSON via
`lib/pithead/30a-go-masked-config.sh`; `make test-go-config-masked-parity` compares
bytes and fallback. Validation, file transactions and HMAC execution stay in Bash.
`go/internal/config/worker_read.go` handles the read-credential map's JSON stages via
`lib/pithead/30b-go-worker-read.sh`; `make test-go-worker-read-parity` compares
bytes and failures. Validation, HMAC execution and file transactions stay in Bash.
`go/internal/config/ssh_settings.go` and `node_credentials.go` validate SSH policy and plan RPC
credentials through `lib/pithead/27k-go-config-access.sh`; `make test-go-config-access-parity`
checks state, callback order and complete renders. Username reads, generation and persistence stay in Bash.
`go/internal/config/wallet_settings.go` validates the required-wallet gate through
`lib/pithead/27j-go-wallet-settings.sh`; `make test-go-wallet-settings-parity` checks
state, error order and full renders. Mode getters and checksum classifiers stay in Bash.
`go/internal/config/payout_settings.go` parses payout-confirmation scalars via
`lib/pithead/27i-go-payout-settings.sh`; `make test-go-payout-settings-parity` checks
validation and partial state. Time and wallet-ownership/curve checks stay in Bash.
`go/internal/config/site_names.go` expands the shared Caddy/certificate names and formats SANs
through `lib/pithead/26a-go-site-names.sh`; `make test-go-site-names-parity` checks
filters, ordering and complete Caddy renders. Discovery and shell expansion stay in Bash.
`go/internal/config/caddy_bind.go` filters supplied bind candidates through
`lib/pithead/35c-caddy-go-bind.sh`; `make test-go-caddy-bind-parity` checks complete
renders and callback order. Discovery and public-IP classification stay in Bash.
`go/internal/config/caddy.go` serializes all Caddyfile sections from
prepared state; `make test-go-caddy-parity` compares full file bytes, logs,
statuses and preparation calls. `go/internal/config/caddy_sites.go` formats
site URLs and scheme-default ports; `make test-go-caddy-sites-parity` checks host
expansion, ports and framing. The adjacent `lib/pithead/35a-caddy-go-render.sh`
hook supplies Bash-expanded hosts through the tagged `sites-v1` protocol,
retaining the legacy frame. `go/internal/config/caddy_auth.go` prepares auth blocks
and the boot digest through `lib/pithead/35b-caddy-go-auth.sh`;
`make test-go-caddy-auth-parity` checks complete renders and preparation fallback.
Bash keeps host expansion, address discovery/classification, bcrypt/certificate
preparation, reference port preparation and file writes. `go/internal/config/env.go`
serializes the complete ordered `.env` batch via `lib/pithead/33a-go-env-render.sh`.
`make test-go-env-parity` adds byte/protocol comparisons; the unchanged sparse
render fixture and goldens remain the oracle. `go/internal/config/env_network.go`
derives daemon routing, profiles, binds and P2Pool settings via
`lib/pithead/33b-go-env-network.sh`; `make test-go-env-network-parity` compares
complete renders. `env_dashboard.go`, `env_alerts.go` and `env_workers.go` derive
the dashboard-facing CLI values and ordered worker token JSON through
`lib/pithead/33c-go-env-dashboard.sh`; `make test-go-env-dashboard-parity` compares
those settings with complete reference renders. `go/internal/config/env_memory.go`
derives memory settings and the Tari auto ceiling through
`lib/pithead/33d-go-env-memory.sh`; `make test-go-env-memory-parity` checks limits
and hardware boundaries. Bash retains hardware discovery, secret-file preparation
and writes. Remaining typed checks stay Bash.
The owner's 2026-11-01 Go scope covers CLI/backend application code, followed by
shipping documentation and release/dashboard/appliance build integration. Host
scripts and container entrypoints retain their reference implementations.

Raw config checks live in `lib/pithead/22a-config-document.sh` and
`dashboard/mining_dashboard/config/documents.py`; the browser JSON editor checks duplicates
in `dashboard/mining_dashboard/web/static/config/jsondocument.mjs`.
Both reject duplicate members before normalization and placeholders before staging or masking.

Webhook member validation is shared by CLI apply and control previews in
`lib/pithead/27-defaults-and-config-validation.sh`. Its RC trigger is in
`tests/stack/control/test-control-secret-and-dial-guards.sh`;
`tests/integration/lib/run-webhook-validation.sh` exercises the real control spool in hardening.

`scripts/release/appliance.sh` builds and verifies the appliance assets before draft creation;
`tests/os/selftest-release-appliance.sh` supplies refusal controls, and the KVM update phase
checks real dev-signed artifacts through the same identity verifier.

Release-note extraction is covered by `tests/stack/release/test-release-notes.sh`;
it selects the changelog section matching the release tag, including known issues.
The release-command and shipped-note guards in
`tests/stack/standalone/test_appliance_release_docs.py` run through `make test-tools`.

The CLI is concatenated in `LC_ALL=C` filename order, keeping the distributed
executable self-contained. Do not nest or reorder `lib/pithead/` slices without
checking that contract. `make lint-pithead-build` checks assembly and ordering
guards. Sources are excluded from release bundles.

Doctor verdict ids are pinned in `tests/stack/doctor/check-ids.py`;
`tests/stack/doctor/test-doctor-appliance.sh` checks the JSON and support-bundle rows,
and the surface and memory suites check that an id survives verdict and wording changes.

Container restart observation is shared by status and doctor in
`lib/pithead/04a-container-restarts.sh`; its Docker and Podman fixtures are in
`tests/os/selftest-container-restarts.sh`, and the appliance Caddy crash-loop proof runs in the
KVM `stack` phase through `tests/os/container-restart-leg.sh`.

The migration startup regression is `tests/stack/lifecycle/migration-hold.sh`;
`tests/os/selftest-migration-hold.sh` checks slot ownership and same-version fallback.
The provision migration fixture is `tests/os/migration-recovery.sh`: it seeds the release through
the selected old dashboard writer in `migration-release-snapshot.py`, and measures post-commit
mining with `migration-readiness.py`. `selftest-migration-recovery.sh` and
`selftest-migration-snapshot.sh` check ancestry refusal, persistence and recovery contracts.
The runner input and acceptance contract is in `tests/os/migration-recovery.md`.

Reset slot preservation is in `lib/pithead/16b-reset-slot.sh`; its fixture controls live in
`tests/stack/appliance/test-appliance-reset-slot.sh` and
`tests/stack/appliance/test-appliance-reset-slot-boot.sh`.
The fresh-spare negative control is in `tests/os/phases/update-spare-slot.sh`.
The real A/B reset leg is `tests/os/phases/reset-slot.sh`; it checks wizard setup, CLI restore
and reboot with setup still open before the final provisioned reboot.

Configless shutdown and the local reset destination record are in
`lib/pithead/01a-configless-recovery.sh`; restore's active-stack and destination guards stay in
`16a-restore-safety.sh`. Regression coverage is `tests/stack/test-restore-configless.sh` and the
lifecycle leg `tests/integration/lib/run-reset-restore.sh`, with failure controls in
`tests/integration/selftest/selftest-reset-restore.sh`. Candidate-compatible fixture projection,
original-byte cleanup and private recovery retention are exercised by
`tests/integration/selftest/selftest-reset-recovery-fixture.sh`. Shared web ownership checks are in
`tests/integration/lib/reset-restore-web.sh`; consecutive status censuses are in
`tests/integration/lib/readiness-churn.sh`.

Appliance reset leg 0 is `tests/os/phases/reset-config.sh`. Its guest-only
`tests/os/reset-config-probe.sh` records the real Compose shutdown status and output before
configuration removal, including suppressed RC4 diagnostics. `tests/os/selftest-reset-config-probe.sh`
checks that failed or unrecorded stops cannot pass from reset's final exit 0.

The stratum port preflight is `lib/pithead/39a-stratum-port-preflight.sh`; preview and apply
probe changed ports before committing. `tests/stack/standalone/test_stratum_port.py` checks live
listener conflicts, and the hardening phase runs `tests/integration/lib/occupied-stratum.py`
through the dashboard control API against Caddy’s occupied port. It waits for workers and hash
progress before preview and after refusal, reporting bounded counters when either wait fails.
The pre-preview wait re-baselines a counter reset from the preceding apply, then requires growth;
the post-refusal check still requires growth beyond the established baseline.

The apply sync-gate marker helper is `lib/pithead/40a-sync-gate-reset.sh`; it remains
part of the generated CLI and is loaded before main dispatch.
The host-only configuration stamp and both restore version checks are in `27a-config-version.sh`;
its shell regressions are in `tests/stack/config/version.sh`. The Configuration newer-config warning card is
`web/static/config/configversion.mjs`, with response metadata in `service/config_operations.py`.
The host firewall installer is `02b-tor-egress-apply.sh`; the host-owned clearnet
sync transition and attestation are in `02c-tor-egress-sync.sh`, and live rule
readback helpers are in `02d-tor-egress-verify.sh`.
The LAN source rule and old-listener stop are in `02b-lan-guard.sh`; the staged Compose passes
and scoped node restarts are in `02b1-lan-guard-compose.sh`. Transition prearm and the periodic
live-rule check are in `02c-lan-guard-check.sh`.
Explicit saturated Tor circuit-history recovery is in `02e-tor-recovery.sh`;
its read-only authenticated bootstrap probe is `build/tor/recovery-diagnose.sh`;
the dashboard's clearnet healer stays in `service/health/tor_heal.py`, with host
history observations and recovery results in `service/health/tor_heal_history.py`.
The automatic `tor-recover` control wrapper is `48b-control-tor-recover.sh`; it calls
the same host-gated recovery as the CLI.

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
| `web/views/sovereign_views.py` | Opt-in lean UI route | `tests/web/views/test_sovereign_views.py` |
| `web/server.py` | HTTP application setup and route registration | `tests/web/` |
| `wizard/server.py`, `wizard/form.py`, `wizard/defaults.py` | Appliance wizard server, disk-based defaults, form translation, and install handoff | `tests/web/test_wizard*.py` |
| `wizard_*.py` | Wizard config shaping, install validation, node probe, recovery, submission transaction and cleanup, plain-port redirect | `tests/web/test_wizard*.py` |

`service/access_log.py` bounds reads of Caddy's active and rotated access logs;
`service/audit_service.py` sanitizes and summarizes those records. Rotation tests
live in `tests/service/test_access_log.py`.

`tests/service/network/prove-clearnet-replay.sh` runs the marker replay cases through
`make test-clearnet-replay-proof`. The GitHub dashboard job retains the source commits,
Linux/ext4 identification and all 100 case verdicts in its output.

Keep polling order, database locks, and transaction scopes intact when extracting
helpers. The storage mixins share `StateManager`'s connection and lock; the
atomicity and annotation tests in `tests/service/` check those boundaries.

`lib/pithead/31a-miner-connection.sh` resolves wizard connection credentials, carries the
installer's TLS identity to target data and computes the public fingerprint. The dashboard's
`web/miner_connection.py` exposes rendered connection values through a separate uncached route;
`web/static/workers/minerconnection.mjs` renders the block. Its API and frontend tests live in
`tests/web/test_miner_connection.py` and `tests/frontend/workers/minerconnection.test.mjs`.
`tests/os/selftest-miner-connection.sh` proves the host carry and hostile-target guards without a guest.
`tests/os/miner-connection-leg.sh` checks hand-off identity after setup and installation;
`tests/integration/lib/miner-connection.sh` checks the running dashboard against the installed
password and certificate. Both have mutation self-tests beside their harnesses.

`lib/pithead/12a-wizard-addresses.sh` supplies non-bridge host addresses for the
setup container and prints the journal and physical-console connection announcements.
`tests/os/wizard-redirect-leg.sh` checks the plain-port
redirect from outside the guest during boot and provision, and Caddy after setup;
its fake-transport cases run through `selftest-wizard-redirect.sh`.

`python -m mining_dashboard.wizard` remains the appliance's wizard launch command;
the package's `__main__.py` delegates to its server.

Browser assets live in `web/static/`. The opt-in lean preview is in `web/static/sovereign/`,
with its template at `web/templates/sovereign.html`; its frontend tests are in
`tests/frontend/sovereign/`. Shell and Earnings browser journeys are
`dashboard/tests/browser/sovereign.test.mjs` and `dashboard/tests/browser/sovereign-earnings.test.mjs`.
The Earnings page, payout presentation and scoped host-control adapter are in
`web/static/sovereign/earnings.mjs`, `earnings-model.mjs` and `earnings-control.mjs`.
The browser workflow retains sanitized shell, drawer and Earnings screenshots as
`sovereign-visual-proof`, including passing runs.
JavaScript feature folders are `app/`,
`config/`, `network/`, `system/`, `workers/`, `xvb/`, and `wizard/`.
`tests/frontend/` mirrors those folders. Its `harness.mjs`, `helpers/`, and
`fixtures/` provide shared test inputs and rendering support. Node discovers the
nested tests through `make test-frontend`.
`dashboard/tests/browser/` holds Playwright user journeys, an isolated local fixture server,
and Chromium/Firefox/WebKit/mobile projects. `make test-browser` runs them after browser
installation; `browser.yml` runs the same suite and retains failure artifacts.
[Browser testing](browser-testing.md) maps coverage and live acceptance limits.
The same fixture serves the production setup page for restore-upload journeys; API responses,
archives, credentials and disk targets remain synthetic and confined to loopback.
The earnings regression serves the production calculator and supports pre-fix asset controls.
The separate HTTPS backup fixture verifies complete encrypted downloads in Chromium and pinned Chrome.

`dashboard.css` imports the ordered files in `styles/`; wizard styles stay in
`wizard/`. `vendor/` contains third-party browser libraries and their provenance.
Keep local code out of `vendor/`.

The Tari-off preview regression is `tests/stack/control/test-control-editable-allowlist.sh`;
`tests/integration/lib/run-tari-off-preview.sh` exercises the combined candidate through
the deployed CLI during the hardening phase.

## Shell suites and tools

| Directory | How it runs |
|---|---|
| `tests/stack/` | `run.sh` loads the shared harness and an explicit ordered list of feature suites, cut into five blocks that CI runs as parallel jobs. Missing or failed sources fail the run. The Tor section includes `test-tor-port-validation.sh` for entrypoint rejection before rendering or launch. `test_setup_build_interrupt.sh` runs independently in a stack block and covers a Tor-build SIGINT, retained configuration, failure diagnostics and a successful retry. The standalone `test_checklist.sh`, called by block 1, validates the manual QA samples and every broken-config refusal, including unchanged rendered state and no Compose startup. |
| `tests/stack/{appliance,control,dashboard,doctor,lifecycle,release,secrets}/` | Feature assertions loaded by the stack runner; retain shared setup and cleanup order. Dashboard database-copy checks live in `control/test-dashboard-carry.sh`; apply recovery stays in `control/test-control-deploy.sh`. |
| `tests/stack/standalone/test_grub_hugepages_real.sh` | Normal-user hosted regression using native GRUB tools in a private mount namespace; checks cloud drop-in precedence, rerun stability and a missing-drop-in control. The Shell workflow also requires it to fail on RC2. |
| `tests/stack/lib/` | Shared harness modules and sandbox builders used by feature fragments; `control-fixtures.sh` and `backup-fixtures.sh` initialize independent prerequisite runs. `config-document-parser.py` holds CLI decoder cases invoked by `test-config-document.sh`; dashboard decoder tests stay in the dashboard image context. |
| `tests/stack/standalone/` | Independent suites invoked by Make and CI, including Compose validation. `test_clearnet_attestation.py` exercises the CLI reader with host-claim and replay metadata; it needs the repository CLI sources and stays outside the dashboard image context. |
| `tests/integration/lib/` | Sourced helpers and phase functions for the live harness. `run-pool-preview.sh` checks routing-only P2Pool previews in lifecycle using an isolated candidate config. `parent-lock.sh` drains the inline pregate process group before restore (`inline-pregate-remote.sh` verifies the SSH-side groups) and reaps the wrapper’s own loaner child afterward; `worker-detail-diagnostics.sh` projects judged Worker Inspect failure responses without identities or secrets. `fault-rules.sh` removes `pithead-e2e-fault-*` firewall rules from every running container's network namespace before a fault leg and when the harness exits. `run-rotate-secrets.sh` streams `tests/integration/rotate-auth-probe.py` to the dashboard for bounded HTTP and stratum authentication checks; `borrow-fixture.sh` owns the controller's rig credential and restoration handshakes. `run-pool-sync-fault.sh` injects bootstrap pool stats and checks the dashboard sync state and recovery, with trap-protected restoration; its selftest checks failures and cleanup without Docker. `restore-chain-sync.sh` streams the read-only `restore-chain-sync.py` daemon proof to the restored baseline. The restoration transport uses libcurl Digest; `tests/integration/selftest/selftest-restore-curl-connection.sh` exercises its challenged connection against a bounded synthetic server in CI. `wallet-fixture.sh`, `wallet-fixture.py` and its adjacent `wallet_fixture_capture.py` preserve legacy and fingerprinted Monero caches through destructive tests and verify them before releasing the reservation. `wallet_fixture_supersession.py` owns retained snapshot retirement; `tools/prove-wallet-supersession.py` exercises it in lifecycle. `wallet_fixture_recovery.py`, its private proof store `wallet_fixture_recovery_record.py` and its `wallet-fixture-recovery.sh` steps restore a retained snapshot after its job ended ([wallet-recovery.md](wallet-recovery.md)); `tools/prove-wallet-recovery.py` runs that operator entry point against a separate private snapshot in lifecycle. |
| `tests/integration/payout-pairs/` | Isolated live apply, wallet services and dashboard. The Docker API guard limits fixture apply to its private storage and Compose project. The initial env carries only the synced nodes’ provisioning identities, leaving runtime state and wallet passwords to the fixture’s actual apply. Image lookup loads all source profiles so the wallet’s node dependency is present, and refuses a failed Compose model before pulling. `test-payout-pair-preparation.py` covers preparation and env isolation without creating containers. The model transform accepts environment lists and mappings while preserving unexpanded values; `test-payout-pair-model.py` checks both forms and the isolation contract. Apply uses the caller’s uid/gid so its owner-only files remain readable; successful cleanup exposes only the private scratch tree to a restricted removal container. Wallet identity checks follow a bounded readiness poll that requires fresh direct health and height checks even when dashboard cards still show cached success; `test-payout-pair-runtime.py` covers startup retries, deadline failures and invocation ordering. The fixture carries no dashboard login and an inert `caddy` stub, so apply’s real Caddy restart has a target without a proxy; the guard prints the rule behind any denial (never the request body) into the apply log. |
| `tests/integration/selftest/` | Harness logic and bounded local transport fixtures; `selftest-wizard-defaults.sh` runs the real CLI wizard with the runner baseline contract and stubbed deployment I/O. `make test-integration-selftest` also checks appliance module loading. |
| `tests/integration/tools/` | Explicitly invoked chain preparation and test-host inspection tools. `doctor-tip-time.sh` runs both doctor formats against the live stack with a zero-timestamp RPC response during the check phase. |
| `tests/integration/mergemine/` | Tari validator fixture and recording Tari node for the `--mergemine-submit` leg (#2586); LocalNet read-back probe for the `--mergemine-localnet` leg (#2589). Test-only, built on the bench. |
| `tests/integration/fakes/`, `mini-stack/` | Fake-daemon contracts and containerized end-to-end checks. `mini-stack/telegram-command-wire.py` checks Telegram command replies, chat restriction, offsets and replay through the real dashboard loop; `mini-stack/telegram-network-stats.json` seeds its synced P2Pool state. `fakes/test_fake_sink.py` checks the HTTP queue and stats fixture. `fakes/test_masked_config_read.py` exercises raw host config through the CLI renderer and dashboard reader. |
| `tests/os/lib/`, `phases/` | Shared appliance harness functions and ordered boot/install/update/fault phases. `rig-config-meta-wait.sh` waits for refreshed provenance before the rig reboot comparison; `selftest-rig-config-meta-wait.sh` covers stale, absent and invalid feeds without a guest. `rig-share-leg.sh` and `selftest-rig-share.sh` cover address/hostname/return share windows and their failure controls. |
| `tests/os/rig-share-leg.sh` | Coordinator power-cut recovery after the address/hostname/return share windows; `selftest-rig-share-power-cut.sh` checks counter resets, worker identity, stale/error responses, real PASS/FAIL accounting, credential transport, cleanup and guest isolation without KVM. |
| `tests/os/rig-adopt-leg.sh` | Dashboard control-route adoption and reversible rig config push after the share leg; `selftest-rig-adopt.sh` checks adoption, API reachability, refusal, unchanged pools, restoration and token non-disclosure without guests. |
| `tests/os/appliance-*-leg.sh` | Self-contained assertion legs the phases call (hostname, diagnostics, config approval, Tor-egress enforcement, post-commit chain fault). Monero RPC visibility uses `monero-quadlet-proof.sh` during provision, with isolated fixture resource rewrites in `monero-quadlet-unit.awk` and wrapper regressions in `selftest-monero-rpc.sh`. The installer restore uses `restore-live-state-verdict.sh` for the configured-wallet comparison and bounded P2Pool startup window, with controller restoration and crash cases checked by `selftest-restore-p2pool-startup.sh`. The post-commit fault leg uses `chain-fault-timing.sh` to read the live dashboard debounce and prove the before/after window; `selftest-chain-fault-timing.sh` covers its deadlines and negative controls. The XvB stubbed polling fixtures share `tests/os/xvb-selftest-clock.sh`; `tests/os/selftest-xvb-poll-clock.sh` checks independence from host scheduling. Other legs carry a `--self-test` driven from tier 1 by `tests/stack/test-harness-tooling.sh` or `tests/os/selftest-row-payloads.sh`, so its logic is provable without a KVM. |
| `tests/os/console-login-probe.py`, `tests/os/headless-install-leg.sh`, `tests/os/media-password-leg.sh` | Guest-only console hash/volatile-overlay checks, installer preseed assertions and USB password recovery. Tier-1 controls are `selftest-console-login.sh`, `selftest-headless-install.sh`, `selftest-installer-preseed.sh` and `selftest-media-password.sh` under `tests/os/`. |
| `tests/runner/` | The pinned Linux image `make test-container` runs the other tiers inside, so a macOS or Windows host reaches CI's verdict. Built and CVE-scanned by `test-images.yml`; reaches no user. |
| `scripts/lint/` | Gates invoked by `make lint`; selftests live beside the gate they exercise. |
| `scripts/watch/` | Scheduled checks invoked by `.github/workflows/`. `pin-watch.sh` compares pins; `pin-watch-issues.sh` reconciles actionable upgrade issues. Its offline cases live in `tests/watch/`, invoked through the watcher’s `--self-test`. |

`tests/os/install-keep-plant.sh` stages the reinstall dashboard image in the guest,
with sub-step failure diagnostics and cleanup; `tests/os/selftest-install-keep-plant.sh`
drives command failures without mounting a disk or starting Podman.

The daily soak reader is `tests/os/soak-probe.sh`. Its fixed remote collector is
`soak-read.sh`, local derivations and live-read verdict are in `soak-record.sh`, and
extended canned cases are in `soak-selftest.sh`, all under `tests/os/`. The workstation
helper `soak-local.py` supplies portable UTC, hashing, decoding and bounded SSH execution.
Its `--self-test` is run by `tests/stack/test-harness-tooling.sh` on Linux and by the
Shell workflow on macOS with system and Homebrew Bash; the provision phase exercises `--read`
on the guest without opening a soak window.

`os/overlay/pithead-boot-version` supplies the display-only menu version for boot, image
creation and disk installation. `tests/os/selftest-build-label.sh` checks all three
writers and the release refusal. `tests/os/build-label-fixture.sh` stamps only debug test
rootfs, and `tests/os/build-label-boot-leg.sh` checks first-menu serial titles.

The mini-stack's `test-boot-health-proxy.sh` renders Caddy against the real dashboard;
`boot-health-proxy.py` verifies boot-probe accounting and network forgery controls,
including the loopback upstream supplied by `boot-health-front-proxy.py`. A fresh log
volume and `caddy-auth-upstream.py` then isolate the login contract: missing/wrong/correct
credentials, the authenticated actor replacing a spoofed header, and the real audit
parser reading Caddy timestamps, methods, URIs, usernames and exactly two failures.
The provision reboot leg streams `tests/os/boot-probe-evidence.py` into the deployed
dashboard using the same retained-log reader as the summary to check the current boot
marker, header redaction and zero failures, then
one failure after an external wrong-password attempt;
The complete pre-boot log directory is archived before reboot to isolate the controlled window.
`selftest-boot-probe-evidence.sh` checks its negative controls, archive behavior,
diagnostic redaction and delayed current-boot commit.
The checks retain assertion errors and bounded counts in the battery output; raw request,
header and user values are omitted. Bounded current/rolled-log counts expose discarded
records; effective Caddy configuration is reported only as matcher/log-destination flags.

The harness entry points retain their command-line interfaces. Live integration
and appliance runs require a reserved host; local selftests do not start a VM.
`tests/integration/lib/tari-readiness.sh` supplies the running-state battery's fresh
required-Tari observation. `mergemine-probe.sh` in the same directory binds the gRPC
proof to the current container epoch. Their pure controls live in
`tests/integration/selftest/selftest-run-state-tari-observation.sh` and
`tests/integration/selftest/selftest-mergemine-readiness.sh`; Make discovers both through
the existing selftest glob.
Coordinator connection announcements and unchanged-apply miner calls are covered by
`tests/stack/test-connection-announce.sh`; the lifecycle phase runs
`tests/integration/lib/run-connection-announcements.sh` against the deployed DIY CLI.
Its `tests/integration/tools/connection-setup-pty.py` driver answers the real setup prompts
and bounds the child process and captured output.
The stratum authentication and TLS client controls are in
`tests/integration/rotate-auth-probe.py`, with wire, counter and miner fixtures in
`tests/integration/selftest/test_rotate_auth_probe.py`. Both TLS scenarios run the controls;
the KVM stack phase selects `remote-main-stratum-tls` for the appliance's shipped XMRig.
`tests/os/selftest-stratum-controls.sh` registers its appliance fixture checks.

`tests/integration/lib/run-channel.sh` identifies appliances through the shipped CLI
and records counted `by-design` skips for the connection, wallet supersession and wallet
recovery checkout probes; failed identification leaves those probes binding.
`tests/integration/selftest/selftest-probe-channels.sh` covers the channel decision,
skip accounting and missing DIY tools without starting containers.
`tests/integration/lib/xvb-off-dwell.sh` supplies the live disabled-XvB dwell observation
for deploying scenarios and read-only checks; `selftest-xvb-off-dwell.sh` exercises
its log, clock, rejection and transport controls without a daemon.
The source-image module supplies shared read-only lifecycle latch/marker diagnostics to the
connection probe and lifecycle runner. The image fixture uses the shared
`assert_mining_probe_ready` in `run-matrix.sh` to settle a legitimate restore-induced hold.
Its diagnostic, readiness and image selftests use fake Docker I/O.
The provision phase streams `tests/os/appliance-local-miner-leg.sh` to the guest to prove
both local-miner toggles converge without rebooting.
`tests/os/appliance-earnings-leg.sh` checks that the provisioned dashboard serves the checkout’s
parser and earnings modules through authenticated Caddy; `selftest-earnings-assets.sh` rejects
old, missing, redirected and unrelated responses without a guest.
The address-watch provision leg in `tests/os/appliance-address-watch-leg.sh` checks certificate
SAN coverage and the deployed dashboard recovery assets through TLS, then executes the served
fingerprint instruction over SSH. Its refusal controls are in `tests/os/selftest-dashboard-recovery.sh`.
The shared dashboard request poller uses `tests/os/control-request-evidence.sh` for allowlisted
transport metadata, failure snapshots and bounded preview transport recovery; its selftest runs through
`tests/os/provision-browser-submit.sh --self-test`.
The image-upgrade phase also runs `tests/os/image-upgrade-certificate-leg.sh`: a real
GUI update and reboot with a nonpersistent guest address present before and after boot.
`image-upgrade-browser-host.py` uses the host Python runtime to restore that address
only after observing a new boot,
its absence and Caddy running. `image-upgrade-browser.mjs` keeps the original browser
tab, accepts the initial certificate once, and checks the served fingerprint, key and
canonical SANs plus automatic recovery. The browser runs in a digest-pinned container;
SSH credentials stay on the host; Node runs only inside the browser container.
`selftest-image-upgrade-browser.sh` exercises the
certificate comparison and bounded orchestration controls without Docker or a guest.

The lifecycle phase uses `tests/integration/lib/run-tari-background-sync.sh` to prove
continued Monero hashing through a Tari off-to-local apply and warm-chain catch-up.
The provision and setup-defaults phases check firstboot and system journals for bcrypt credentials with
`tests/os/credential-journals.sh`; `selftest-credential-journals.sh` covers leaks and unreadable journals.
The provision phase streams `tests/os/tor-recovery-refusal-guest.sh` after initial provisioning
settles to require a healthy Tor guard refusal without unexpected-abort advice;
`selftest-tor-recovery-refusal.sh` proves the assertion fails on pre-fix CLI dispatch.
Password fixture cleanup lives in `tests/os/appliance-password-fixture.sh`, sourced and selftested by the config-approval leg.
The Tari-mode unreadable-config branch streams `tests/os/caddy-failure-evidence.py`
through `caddy-failure-evidence.sh` for a bounded, allowlisted guest snapshot;
`tests/os/selftest-caddy-failure-evidence.sh` exercises collection and the failure branch.
The opt-in KVM `tor-heal` phase streams `tor-heal-guest.sh` into an isolated guest
to prove No login egress recovery through host NEWNYM and the final healer restart,
plus auto-heal off and unrelated-request rejection with production timers.
Saturated recovery guards remain covered by the host recovery fixtures.
The offline image assertion is `tests/stack/standalone/test_tor_saturated_image.sh`,
run by the Tor image build job. It verifies either startup repair of all 1000 abandoned
observations and an empty persisted history, or the legacy warning and shutdown-write
behavior, then checks stop/move/start recovery. Failures print the phase, the last 80
offline daemon log lines and circuit-build state fields; authentication cookies stay private.
Retained circuit-build bins after automatic repair and retained saturation after final
recovery fail explicitly; neither can reach the completion marker.
Its Docker-free controls are in `tests/stack/standalone/test_tor_saturated_fixture.py`,
run by `make test-tools`.
Bundle staging into the guest is bounded and reports through `staging-failure-evidence.sh`; the
floor-fallback leg stages separately from `os-update` (`selftest-floor-staging.sh`, #3049).
Use `scripts/sanitize-test-log.sh` for bounded build and serial-log excerpts, as
described in the [AI workflow](ai-workflow.md).

The lifecycle phase uses `tests/integration/lib/run-lifecycle-tls.sh` to compare Caddy's
served leaf, canonical SANs, public key and a local digest of its stored private keys
across stopped-stack restore and dashboard password apply. Its pure failure controls
are in `tests/integration/selftest/selftest-lifecycle-tls.sh`;
`tests/os/selftest-tls-continuity.sh` exercises appliance minting with transient address
loss, canonical reordering, genuinely new SANs and unusable pairs.

The e2e hardening phase runs `tests/integration/lib/access_log_retention.py`
against real Caddy requests and the deployed access API. It verifies wrong-password
failures past the old tail limit and native gzip rotation;
`tests/integration/selftest/selftest-access-log-retention.sh` runs its Docker-free
undercount and failure controls.

## What stays at the root

- Runtime contracts: generated `pithead`, `pithead-completion.bash`,
  `docker-compose.yml`, `config.*.json`, `cosign.pub`, and `VERSION`.
- The public bootstrap script, `install.sh`, whose URL is a published interface.
- GitHub and contributor entry points: `README.md`, `CONTRIBUTING.md`, `LICENSE`,
  `SECURITY.md`, and `CODE_OF_CONDUCT.md`.
- Shared agent guidance: `AI_RULES.md`, with relative symlinks from `AGENTS.md`,
  `CLAUDE.md`, and `.cursorrules`.
- Tool-discovered configuration such as `.editorconfig`, `ruff.toml`,
  `biome.json`, and `.pre-commit-config.yaml`. A linter that takes an explicit config
  path instead — yamllint, markdownlint, hadolint, lychee, taplo, gitleaks, trivy — is
  pointed at `.config/` (the invocation is single-sourced in the Makefile or, for
  trivy and gitleaks, in the CI job that runs it).

Release bundles and appliance images use explicit file lists. Moving a source
file does not authorize adding development tools or private evidence to an image.

For test tiers and placement, read [testing strategy](testing-strategy.md) and
[testing guide](testing-guide.md). For configuration values, read
[configuration](../configuration.md). The wizard spool-file protocol is in
[appliance wizard](appliance-wizard.md#host-and-page-spool-files).

Payout confirmation validates private view scalars in `lib/pithead/25b-payout-keys.sh`; the wallet
entrypoints select storage by address/key fingerprint. `tests/stack/test-payout-wallet-pairs.sh`
proves matching keys, derivation, selection and checked legacy adoption. The Tari entrypoint's
`build/tari-wallet/legacy-address.sh` reads the pinned wallet's address RPC from a private database
copy. The isolated `tests/integration/payout-pairs/run.sh` fixture exercises matching adoption and
an upgrade with a changed pair without changing the mining stack's payout configuration.

The setup wizards share host disk budgets through `lib/pithead/11b-wizard-disk-budget.sh`;
the appliance publishes them beside the disk inventory for both submission paths.
CLI payout retries and EOF config preservation run in
`tests/stack/test-wizard-addresses.sh`. The lifecycle phase repeats EOF and retry checks
through `tests/integration/lib/run-wizard-eof.sh` and `run-wizard-defaults.sh`, then
deploys the valid wizard configuration and checks service health.

`tests/os/phases/setup-defaults.sh` proves a fresh appliance with the wizard defaults,
without the explicit Tari opt-in used by the general provision phase.

Persistent DIY HugePages boot configuration lives in `lib/pithead/37a-grub-hugepages.sh`;
`lib/pithead/37-kernel-tuning-and-preflight.sh` calls it during setup.
`tests/stack/test-grub-hugepages.sh`, loaded alongside the wizard setup suite, covers cloud
drop-in precedence, ISO defaults, idempotency and generated-entry failures.

The ENOSPC fault lifecycle is `tests/integration/lib/disk-enospc-target.sh`, transmitted
through the shared target wrapper by `run-faults.sh`. Its mount ownership and interruption
controls are in `tests/integration/selftest/selftest-enospc-cleanup.sh`.

The e2e wrapper captures required pre-run systemd unit states through
`tests/integration/lib/restore-unit-state.sh`. Restoration checks their capture records before
unit removal; `tests/integration/selftest/selftest-restore-unit-capture.sh` covers failed reads
and state lost between preflight and restoration.
