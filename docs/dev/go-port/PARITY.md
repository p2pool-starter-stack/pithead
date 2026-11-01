STATUS: IN PROGRESS

# Go port parity

Incremental port for issue #3811, based on
`a73ffced33800de9435779a9cabef53864455acb` on branch `go-port/3811`.
The operator commits and pushes each round; Git metadata is read-only. No performance benefit is claimed.

## Scope and continuation criteria

The owner's 2026-11-01 ruling limits application reimplementation to the CLI
and dashboard backend, including the wizard and control channel. Appliance host
scripts and container entrypoints are not being reimplemented. After those ports,
shipping documentation and integration for the release bundle, dashboard image
and appliance image build are in scope, retaining Bash/Python fallback. The
dashboard selection switch remains part of its launch contract. Preserve upstream
daemons, browser assets, runtime filenames, database migrations and wire formats.

The operator loop stops around 2026-11-02 22:00Z; access ends 2026-11-03.
The operator's 15:30Z ruling moves the dashboard ahead of further CLI refinement,
until Go serves its contracts on existing and corrupt databases.
Fleet tests may target pushed heads through the normal bench API, following its
contracts with `submitted_by=gpt-6.1-sol/developer`, a #3811 note and an idempotency
key. Keep topology private. A separate session owns performance work: leave its
`BENCHMARK.md` document and the `tests/go-parity/bench/` tree untouched.

The existing Bash and Python suites are the parity oracle. Do not port, rewrite,
replace or weaken them, their fixtures or their checks. Every slice requires
those suites to pass unchanged with `PITHEAD_IMPL=go`; Go unit tests and new
comparisons supplement that proof. An unavailable original suite leaves that
part of the parity claim unproven.

Each CLI slice must match stdout, stderr, exit status and persistent-file bytes.
The dashboard must retain every HTTP/JSON contract and start on existing and
corrupt databases with the same migration and recovery behavior. A fallback pass
does not prove native Go behavior. `STATUS: COMPLETE` requires every existing
suite runnable locally to pass unchanged under Go selection.

Bench measurement requirements are retained with the
[baseline contract](results-baseline.md#bench-measurement-contract); performance
evidence is maintained by its separate owner.

## Build and selection

```bash
make go-build
make go-dashboard-build
PITHEAD_IMPL=go ./pithead --help
PITHEAD_IMPL=bash ./pithead --help
make test-go-parity
```

The Go module has no third-party dependencies and uses Go 1.23 language features;
local builds use Go 1.27.1. Make confines `GOCACHE`, `GOMODCACHE`, `GOPATH` and
`TMPDIR` under `.go-cache/`; uv uses `.uv-cache/`. Both caches and `go/bin/` are
ignored.

Executing the generated CLI with `PITHEAD_IMPL=go` selects `go/bin/pithead`.
Sourcing it still defines Bash functions. Unported commands exec Bash with the
same argv, streams, exit status and inherited descriptors, setting
`PITHEAD_IMPL=bash` to prevent recursion. `PITHEAD_GO_BINARY` supports copied
fixtures and `PITHEAD_GO_REFERENCE` carries the original invocation path. Unset,
`bash` and `python` keep the reference implementation. Dashboard container
selection is not implemented.

## Components and verbs

| Component / verb | Go status | Parity evidence |
|---|---|---|
| CLI dispatcher and fallback | Implemented | 12-group paired CLI suite and Go units |
| `help`, `-h`, `--help` | Native, except logs passthrough | Paired CLI suite and Go units |
| `version`, `-V`, `--version` | Native | Paired CLI suite and Go units |
| `status` | Native bare command; flags, chains and missing Docker fall back | 9-group paired status suite and Go units |
| `doctor` | Go JSON formatting with Bash collection; human, terminal JSON and unsupported cases fall back | 13-group paired JSON suite and Go units |
| Doctor memory and clock probes | Native packages; Bash collector | 11 tagged comparison groups and Go units |
| Doctor engine, boot, CPU and dependencies | Native packages; Bash collector | 9 tagged host groups and Go units |
| Doctor release verification and engine availability | Native packages; Bash collector | 4 tagged verification groups and Go units |
| Doctor control units and local-miner HugePages gate | Native packages; Bash collector | 9 tagged control groups and Go units |
| Grouped disk checks for doctor and setup preflight | Native package; Bash callers | 8 tagged disk groups and Go units |
| Missing data directories and deployment state | Native packages; Bash callers | 8 tagged data/deployment groups and Go units |
| Tor onion-address report | Native probe; Bash doctor collector | 8 tagged address groups and Go units |
| Shared dashboard onion text | Used by native status and doctor packages | Existing status comparisons and Go units |
| Monero/Tari address classifiers and config diagnostics | Native packages; Bash config readers and doctor collector | 11 tagged comparison groups and Go units |
| Public-IP classification, stratum exposure/listening and Tor runtime | Native packages; Bash doctor collector | 16 tagged comparison groups and Go units |
| LAN firewall readback, boot holds and access diagnostics | Native packages; Bash doctor collector | 20 tagged groups and Go units |
| Docker Tor egress readback and doctor report | Native packages with supplied config/sync state; Bash collector | 18 tagged groups and Go units |
| nft Tor egress readback and doctor report | Native when nft is present; missing-nft compatibility fallback; Bash collector | 8 tagged groups and Go units |
| Tor sync-IP selection and markers | Native with supplied getter/state-dir values; Bash readers | 11 marker/selection scenarios and Go units |
| Tor history saturation, current egress and doctor report | Native probes with supplied mount/config values; Bash collector | 6 tagged comparison groups and Go units |
| Tor heal outage transitions and validity | Native canonical-record planner/validator; Bash locks and persistence | 2 tagged groups, 28 scenarios and Go units |
| Container restart observation and revenue readiness | Native probes with supplied migration hold; Bash collector | 8 tagged groups and Go units |
| Monero sync, peer counts and tip age | Native probes with supplied RPC getters/time; Bash collector | 9 tagged groups and Go units |
| Remote Monero RPC preflight | Native package with supplied endpoint/login/cap; Bash config readers and orchestration | 9 tagged groups, 87 scenarios and Go units |
| ZMTP greeting, READY and exchange verdict | Native canonical-hex validators and supplied-result classifier; Bash network exchange | 8 tagged groups, 451 scenarios and Go units |
| ZMTP stream exchange | Native over supplied connection/deadline; Bash dial and callers | 5 tagged groups, 435 scenarios and Go units |
| Shared container-engine selection | Native `host.Engine`, used by native status and doctor packages | Go units and tagged Bash comparison |
| Lifecycle option parser | Native for five verbs; Bash callbacks and compatibility fallback | 10 supplementary methods, Go units and unchanged 12-group CLI suite; full Linux lifecycle oracle unavailable |
| `setup` | Bash fallback | Not independently proven in Go mode |
| `apply` | Native option validation; Bash operations | Unchanged CLI suite and supplementary boundary comparisons; full Linux lifecycle suite unavailable |
| `render` | Native option validation; Bash operations | Unchanged CLI suite and supplementary boundary comparisons; full Linux lifecycle suite unavailable |
| `up` | Native option validation; Bash operations | Unchanged CLI suite and supplementary boundary comparisons; full Linux lifecycle suite unavailable |
| `down` | Native option validation; Bash operations | Unchanged CLI suite and supplementary boundary comparisons; full Linux lifecycle suite unavailable |
| `restart` | Native option validation; Bash operations | Unchanged CLI suite and supplementary boundary comparisons; full Linux lifecycle suite unavailable |
| `tor-recover` | Bash fallback | Not independently proven in Go mode |
| `upgrade` | Bash fallback | Not independently proven in Go mode |
| `logs` | Bash fallback | Refusal fallback covered by paired CLI suite |
| `test-alert` | Bash fallback | Not independently proven in Go mode |
| `support-bundle` | Bash fallback | Not independently proven in Go mode |
| `reset-dashboard` | Bash fallback | Not independently proven in Go mode |
| `config-reset` | Bash fallback | Not independently proven in Go mode |
| `factory-reset` | Bash fallback | Not independently proven in Go mode |
| `backup` | Bash fallback | Not independently proven in Go mode |
| `restore` | Bash fallback | Not independently proven in Go mode |
| `uninstall` | Bash fallback | Not independently proven in Go mode |
| `firstboot-wizard` | Bash fallback | Not independently proven in Go mode |
| `load-images` | Bash fallback | Not independently proven in Go mode |
| `local-miner` | Bash fallback | Not independently proven in Go mode |
| `os-update` | Bash fallback | Not independently proven in Go mode |
| `control-run-pending` | Bash fallback | Not independently proven in Go mode |
| `egress-run-pending` | Bash fallback | Not independently proven in Go mode |
| `egress-status` | Bash fallback | Not independently proven in Go mode |
| `lan-guard-check` | Bash fallback | Not independently proven in Go mode |
| `onion-client-key` | Bash fallback | Not independently proven in Go mode |
| `rotate-dashboard-onion` | Bash fallback | Not independently proven in Go mode |
| `rotate-secrets` | Bash fallback | Not independently proven in Go mode |
| `render-quadlet` | Bash fallback | Not independently proven in Go mode |
| Raw config document parse/validation | Native Go-selected gate, with Python compatibility fallback | 5 tagged groups / 134 scenarios, unchanged parser and wiring suites |
| Parser document, webhook and control-character sequence | Native supported single-read validation; Bash callbacks and full-sequence compatibility fallback | Unchanged 7-test raw-parser suite and render fixture/goldens; 9 supplementary methods and Go units; full Linux CLI oracle unavailable |
| Config defaults, materialization and getters | Native with runtime table; jq compatibility fallback | 5 tagged groups / 744 scenarios and wiring/render-fixture tests |
| Worker, energy, webhook and control-character validation | Native Go-selected validators; jq compatibility fallback | Paired validator corpus and wiring checks; Go units |
| Stratum bind and port parsing | Native for supported settings; Bash compatibility fallback | Unchanged 14-test stratum preflight and render fixture; supplementary byte/status/state comparisons and Go units; full Linux suite unavailable |
| Caddyfile serialization, site URLs, bind plan and auth preparation | Native fragments, site/port formatting, bind filter, auth blocks and boot digest; Bash bind-candidate public-IP checks, discovery, bcrypt, certificate minting and writes; compatibility fallback | Supplementary Caddy/host/port comparisons and Go units; Linux/Docker oracle unavailable |
| Tari wallet secret publication | Native current-owner publication and direct ownership repair when permitted; Bash directories, dry-run, sudo and compatibility fallback | Matching-UID native success, unprivileged cleanup/fallback, protocol comparisons and Go units; unchanged render fixtures use tool fallback; privileged repair and Linux oracle unproven locally |
| `.env` serialization and regular-file publication | Native bulk formatter and in-place writer; Bash derivation, final chmod, symlink/tool and compatibility fallback | Unchanged render fixture/goldens and native-writer spy pass; supplementary byte/inode/trap/protocol comparisons and Go units; full Linux suite unavailable |
| Daemon network render plan | Native for supported config; Bash hardware/error handling and compatibility fallback | Unchanged render fixture/goldens and supplementary whole-render comparisons |
| Dashboard-facing CLI render values | Native supported scalar/default/worker-token plan; Bash compatibility fallback | Unchanged render fixture/goldens and supplementary whole-render comparisons |
| Memory render settings and auto ceiling | Native for supported settings/facts; Bash discovery and compatibility fallback | Unchanged render fixture/goldens and supplementary hardware-boundary comparisons |
| CPU render plan and outbound-peer bounds | Native supported core facts and peer validation; Bash config/hardware collection, callbacks and arithmetic compatibility fallback | Unchanged memory/network comparisons and render goldens, 8 new methods and Go units; full Linux CLI oracle unavailable |
| Data-directory derivation | Native supported paths/shared-root/default flag; Bash safety checks and compatibility fallback | Supplementary path/state/guard/trap comparisons and unchanged render fixture/goldens; full Linux CLI oracle unavailable |
| Dashboard auth shape and onion/control policy | Native supported credentials/policy; Bash hash reconciliation, warnings and compatibility fallback | Supplementary byte/status/state/order comparisons and unchanged render fixture/goldens; full Linux/Docker auth oracle unavailable |
| Dashboard access settings | Native supported host/port/flag/timezone parsing; Bash host-timezone discovery/default insertion and compatibility fallback | Supplementary byte/status/state/trap comparisons and unchanged render fixture/goldens; full Linux suite unavailable |
| Proxy password, TLS and donation settings | Native explicit/empty settings; auto and unsupported inputs use Bash fallback | Supplementary byte/status/state comparisons and unchanged render fixture/goldens; full Linux suite unavailable |
| Network settings, remote endpoints and pool validation | Native for supported settings; Bash compatibility fallback | Supplementary byte/status/state comparisons and unchanged render fixture/goldens; full Linux suite unavailable |
| Shared Caddy/certificate site names and SANs | Native supported auto-expansion/filtering and SAN formatting; Bash selection/discovery/shell expansion and compatibility fallback | Supplementary comparisons and complete Caddy renders; full Linux/Docker oracle unavailable |
| SSH policy and Monero RPC credential parsing | Native supported SSH validation, password projection and generation plan; Bash username projection, discovery, generation/persistence/log callbacks and compatibility fallback | Supplementary comparisons and unchanged render fixture; original Linux appliance/control oracle unavailable |
| Required wallet fields and Tari mode | Native supported scalar/required/whitespace gates; Bash mode getter, classifiers and compatibility fallback | Supplementary partial-state/callback comparisons and unchanged render fixtures; full Linux CLI oracle unavailable |
| CLI wallet checksum classification | Native supported ordinary verdicts through existing Go decoders; Bash parser diagnostics, Python readiness probe and compatibility fallback | 9 supplementary classifier/gate methods and unchanged render fixture/goldens; full Linux CLI oracle unavailable |
| Payout-confirmation scalar config and restore bounds | Native supported settings; Bash time read, address decoding and compatibility fallback | Supplementary comparisons and unchanged render fixture/goldens; full Linux CLI oracle unavailable |
| Config version policy and stamping | Native supported validation/transform and atomic publication with source ownership; Bash warnings/gates, interposed tools, restrictive umasks and compatibility fallback | Unchanged 16-method version suite and 7 new publication methods, native success spy and Go units; original Linux version suite unavailable |
| Config migrations | Native supported legacy-worker/XvB and Telegram-control plans/transforms; Bash file I/O, callbacks and compatibility fallback | 14 supplementary migration/static comparisons, 2 protocol tests and Go units; original Linux migration suites unavailable |
| Config credential and CLI appliance-default JSON transforms | Native supported ordered JSON transforms; Bash generation, default-table reads, warnings and appliance-default file I/O with jq fallback | 22 supplementary comparisons/static tests and Go units; original Linux suites unavailable |
| Node RPC credential publication | Native for a fresh fixed stage and standard tools; Bash final chmod, existing-stage handling and compatibility fallback | Unchanged persistence suite and 8 new publication methods, native success spy and Go units; Linux secrets/control oracle unavailable |
| Masked config prefill JSON | Native supported ordered transform; Bash validation, file I/O, warnings and worker callbacks with jq fallback | 9 supplementary methods, including 21 paired renders and native/protocol checks; original Linux masking/worker suites unavailable |
| Worker read-credential JSON | Native supported JSON stages; Bash validation, HMAC, warnings and file transactions with jq fallback | 13 supplementary tests, including 25 paired renders and native/protocol checks; original Linux worker-config suite unavailable |
| Config change descriptions and `.env` diff | Native supported messages/flags and byte-order comparisons; callback/locale compatibility fallback | 12 supplementary methods and Go units; original Linux config/approval suites unavailable |
| Payout public-view-key derivation | Native canonical-scalar curve arithmetic; Bash address collection/diagnostics and Python compatibility fallback | 8 supplementary methods and Go units; original Linux payout-wallet-pairs suite unavailable |
| Payout ownership validation | Native supported verdicts with supplied decoded identities; Bash address readers, callbacks and compatibility fallback | Unchanged 8-method payout-key comparison, 9 new methods and Go units; original Linux wallet-pair suite unavailable |
| Shared dotenv decoding and file lookup | Native supported decoder and literal-key lookup; Bash file collection, regex matching and compatibility fallback | Unchanged directory line-break suite, 12 supplementary methods and Go units; broader Linux unit-helper suite unavailable |
| Compose project identity | Native supported C/POSIX resolver; Bash file collection, warning callbacks and compatibility fallback | Unchanged 14-assertion ownership suite, supplementary comparisons and Go units; broader Linux/Docker oracle unavailable |
| Remaining typed validation and config-derived values | Bash fallback | Existing sparse-config fixtures pass with Go helpers |
| Dashboard route/method table, security headers and shell/static/preview transport | Native Go server with explicit Python data/control fallback | 19 unchanged HTTP tests, 7 new comparisons and Go units; full unchanged 3716-test suite passes through adapter |
| Miner connection, XvB standby and Prometheus routes | Native payload/exposition with Go domain computation and Python config/storage inputs; compatibility fallback | Unchanged route suites and new native-ownership comparisons; full backend remains hybrid |
| `/api/state` history chart | Native filtering, downsampling, gaps and markers; Python storage and other state sections | Unchanged chart/state suites through new adapter, supplementary oracle comparisons and Go units |
| Dashboard domain metrics | Native for state and Prometheus requests; Python supplies config/locality and stored/raw snapshots | All 55 unchanged metrics/average tests through the Go adapter, native-ownership guard and Go units |
| History series and headline cards | Native filtering/buckets, payouts, hashrate and cadence; Python storage/config inputs | Unchanged series/state suites through the views adapter, comparisons and Go units |
| System/proxy/Tari/sync/Monero presentation | Native five builders; Python raw snapshots and remaining state assembly | Unchanged infrastructure/Monero/location suites, HTTP ownership guard and Go units |
| Worker rows, RigForge display and energy | Native supported snapshots/config inputs in state; Python supplies descriptors | Unchanged view/worker suites through the new fleet adapter, comparisons and Go units; final results below |
| Host-resource availability and capacity | Native bounded forecast and validation; unsupported large capacity operands fall back | Unchanged resource/state/cost suites through the fleet adapter, comparisons and Go units |
| Remaining state presentation, polling and Tor | Python reference behind Go HTTP routing | Earnings, badges, pool/network and other metadata remain Python; no native polling or complete state proof |
| SQLite schema, migrations and recovery | Python reference, including Go server child | Full unchanged suite passes in hybrid mode; native storage not ported |
| Wizard launch and control channel | Bash/Python reference | Not ported |
| Appliance host scripts and container entrypoints | Application ports excluded, owner ruling 2026-11-01 | Reference scripts retained |
| Go shipping docs, release bundle and image builds | Planned after CLI/backend ports; reference fallback required | Not implemented or validated |

## Harness adapters

The [adapter ledger](adapters.md) lists every supplementary adapter and its reason.
Only new files under `tests/go-parity/` supply those hooks; existing suites remain unchanged.

## Earlier slice results

Detailed paired commands, results and limits are preserved in
[baseline and early results](results-baseline.md), [CLI probe results](results-cli-probes.md) and
[network and firewall results](results-network-probes.md), plus
[remote-node probe results](results-node-probes.md) and
[configuration results](results-config.md), [render results](results-render.md) and
[later render results](results-render-followup.md) and
[later configuration results](results-config-followup.md), plus
[configuration publication results](results-config-publication.md) and
[dashboard HTTP results](results-dashboard.md).

## Native dashboard fleet and resources slice (2026-11-01)

Go now builds worker rows, RigForge chips/inspect rows and release hints, energy
inputs, and host-resource availability/capacity outlook. Worker sorting, skipped
rows, share formatting, power precedence, feed freshness, prices, original sample
times and bounded history resets follow the reference builders. Python supplies
raw snapshots, config descriptors and the existing disk query. State requests
capture those inputs and Go assembles the final three fields without subprocesses.

The resource helper preserves invalid nonfinite samples as invalid numeric inputs
instead of converting them to null. Exact integer conservation avoids rounding
large byte counts into a false valid sample. Native capacity calculations refuse
integer operands beyond exact float range and malformed composites, retaining
Python fallback. Fleet integer formatting and durations retain arbitrary integers;
RigForge timestamp parsing matches Python's accepted forms and rejects fractions.

The backend remains hybrid. Economics, badges, pool/network and base metadata,
polling, SQLite, wizard/control and container selection remain Python. The worker
inspect route still uses Python in production; its shared display builders are
also tested directly through Go. Startup on existing/corrupt databases is still
provided by the Python child, not native storage. No performance claim is made.

The new fleet adapter layers over the existing views/metrics/state/HTTP adapters.
Persistent helpers remove process startup from the unchanged 1000-cycle resource
cost test; every call executes Go with fresh inputs and no cached answers.
The HTTP ownership comparison makes Python workers/energy/resources builders
raise while native state still succeeds. Existing suites and fixtures are unchanged.
Under coverage, the adapter reloads the resource module after tracing starts,
then reinstalls native bindings before collection. This records module setup;
the selected resource calculations still execute Go.

Both full runs use `PYTEST_XDIST_AUTO_NUM_WORKERS=1`. Baseline sets
`PITHEAD_IMPL=python`; Go sets `PITHEAD_IMPL=go`,
`PYTEST_PLUGINS=dashboard_fleet_plugin` and `PYTHONPATH` containing absolute
`tests/go-parity` and `dashboard` directories. Local caches are as documented above.
Commands, exits and private logs use `.go-cache/logs/dashboard-state-fleet-*`.
File-budget checks use `FILE_BUDGET_BASE_REF` at the documented starting SHA.

| Command | Baseline | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3716 unchanged tests, 96.30% Python coverage | Pass; 3716 unchanged tests, 86.86% Python coverage |
| `make test-go-dashboard-fleet-parity` | Original graph supplies expected values; unchanged modules included in full baseline | Pass; 151 tests: 117 unchanged and 34 new comparisons |
| `make test-patch-coverage` | Fails at 80%; reference mode does not execute Go bridge modules | Initial full-suite-only run fails at 76%; current full suite plus A/B append passes at 92% |
| `go -C go test -race -count=1 ./...`; `go -C go vet ./...` | Additive Go checks | Pass after final numeric fixes |
| `GOOS=linux GOARCH=amd64 go -C go build -o "$PWD/.go-cache/dashboard-linux-amd64" ./cmd/dashboard`; `make go-dashboard-build` | Additive Go builds | Pass after final numeric fixes |
| `make test` | Blocked by unchanged shfmt failure in `tests/go-parity/config_defaults_reference.sh` | Same failure |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend test-fakes` | Pass; 891 frontend tests, 54 fake-daemon tests | Pass; same 891 frontend and 54 fake-daemon tests |

Python coverage does not measure Go code. The patch gate is also run after the
full Go-selected suite followed by the new A/B cases with
`PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" make test-go-dashboard-fleet-parity`.
Those cases execute the original Python graph to obtain their expected values
and execute Go independently for the comparison. This combined coverage is
reported separately from the Go-selected full suite alone; untracked new files
are not included in the pre-commit patch diff.
Ruff check and format check pass for the six changed Python files with
`dashboard/pyproject.toml`. Pinned Markdown lint passes for the five changed
Markdown files, using the existing rules with scoped file globs in
`.go-cache/fleet.markdownlint-cli2.jsonc`. The original aggregate gates are unchanged.

The first focused comparison caught the unsupported swap resource losing its
`bytes` unit. That is corrected. Initial Go build ran during an in-progress Go
edit and failed; the subsequent native/race checks passed. Review also caught
large-integer conversion, malformed-capacity fallback and timestamp grammar
differences before final verification. New comparisons cover those boundaries.
Final review found float share grouping, negative-zero formatting and whitespace
in IP octets differing from Python. These are fixed with Go and A/B regressions.
Security review found full endpoint descriptors entering the internal energy
handoff. It now projects only worker names and watts; a regression excludes
credential and connection fields. Security re-review passes.
Legacy RigForge ages and JSON integer `-0` also have regressions; final
adversarial review passes. Existing Make target behavior is unchanged.

Earlier transport, charts, domain metrics and presentation results are retained
in the [dashboard ledger](results-dashboard.md). Adapter details are in the
[fleet adapter note](adapters-dashboard-fleet.md).

## Unavailable and known host constraints

- `make test-stack` deliberately refuses macOS; no Linux suite verdict is claimed.
  The unchanged unit-helper, masking, worker-config and payout-wallet-pairs suites require that harness and remain unproven locally.
- `make test` stops at existing adapter formatting. Independent Markdown lint
  also finds third-party content in the required local uv cache. Changed project
  Markdown is checked separately; the original gates remain unchanged.
- The default file-budget comparison against `develop` finds two pre-existing
  version-branch differences: the firstboot wizard ceiling and a
  provision-browser-submit row. The documented starting-SHA override passes; no
  budget entry changed. Both `PITHEAD_IMPL=bash make lint-file-budget
  lint-pithead-build` and `tests/go-parity/run.sh make lint-file-budget
  lint-pithead-build` report that same default-base failure.
- Integration auth-fail-closed assumes GNU `stat`/`chown`; topology selftests also
  fail on the BSD host. Both failures are identical in the two modes, with the
  checks unchanged.
- Local Compose/Caddy parsing, container/image tests and live matrices require
  Docker/Linux or reserved hardware. Fleet contracts were read over authorized
  SSH; its API has no per-job Go selection option, so no job was submitted for
  this unpushed slice. No live stack or bench was changed.
- Bench measurements and decisions have a separate owner; local test duration
  is not benchmark evidence. Shipping image validation remains pending.

The local CLI-only graph used for navigation covers 96 files, 825 nodes and 1099
edges. Its 14 collapsed relation pairs and tool/skill version mismatch make it a
partial navigation aid, not parity evidence.

## Next

Doctor and Tor/ZMTP probes remain parked. The operator's 15:30Z ruling moves
backend work ahead of further CLI refinement. Next, in order:

1. Port remaining economics/pool/metadata state presentation, then polling; workers, energy and resources now have native builders.
2. Port SQLite schema, migrations and corrupt-database recovery; prove startup on existing/corrupt databases.
3. Port wizard/control, then implement the container selection switch with Python fallback.
4. Return to remaining config/render/lifecycle operations, then CLI verbs starting with `upgrade`, `backup` and `restore`.
5. Update shipping documentation, release bundles, dashboard images and appliance image builds with reference fallback.
6. Obtain Go-enabled fleet proof on pushed heads; keep performance work with its separate owner.
