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
until Go serves its contracts on existing and corrupt databases. The later 19:45Z
review order places the six review fixes first, then native SQLite, wizard/control
and shipping selection/artifacts. G7 escape-byte and G8 privileged Linux proof follow.
The 20:35Z review adds the redaction/topology merge blockers first, then bounded
history transport, inherited ignored signals and corrections to parity evidence.
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

The Go module pins `modernc.org/sqlite` 1.61.1 and its transitive dependencies in
`go.mod`/`go.sum`, requiring Go 1.26 or later. Local builds and the bounded CI job
use Go 1.27.1. Both commands cross-build for Linux amd64 and arm64 with CGO disabled.
Make confines `GOCACHE`, `GOMODCACHE`, `GOPATH` and
`TMPDIR` under `.go-cache/`; uv uses `.uv-cache/`. Both caches and `go/bin/` are
ignored.

Executing the generated CLI with `PITHEAD_IMPL=go` selects `go/bin/pithead`.
Sourcing it still defines Bash functions. Unported commands exec Bash with the
same argv, streams, exit status and inherited descriptors, setting
`PITHEAD_IMPL=bash` to prevent recursion. Only Go-selected fallback exports the
private hybrid marker; the launcher consumes it into non-exported shell state.
Standalone helper adapters also recognize that private marker. The
[legacy fixture adapter](results-review.md#additive-adapters-and-compatibility)
supplies it only to five existing internal-marker test methods. Public reference
selection ignores native helper paths, including `PITHEAD_GO_CONFIG_DOCUMENT_BINARY`.
`PITHEAD_GO_BINARY` supports copied
fixtures and `PITHEAD_GO_REFERENCE` carries the original invocation path. Unset,
`bash` and `python` keep the reference implementation. Dashboard container
selection is not implemented.

## Components and verbs

Numbered comparison groups under `tests/go-parity/` and Go tests were added by
this port; they are supplementary evidence. Original suites are identified
separately. Historical reference arms used the then-current Bash/Python snapshot,
not a frozen starting checkout; the 20:35Z follow-up below adds that comparison.

| Component / verb | Go status | Parity evidence |
|---|---|---|
| CLI dispatcher and fallback | Implemented | New 12-group paired CLI comparisons and Go units; frozen-start comparisons below |
| `help`, `-h`, `--help` | Native, except logs passthrough | Paired CLI suite and Go units |
| `version`, `-V`, `--version` | Native | Paired CLI suite and Go units |
| `status` | Native bare command; flags, chains, missing Docker and already-closed stdout fall back | 9-group paired status suite and Go units |
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
| Lifecycle option parser | Native for five verbs; Bash callbacks and compatibility fallback | 10 supplementary methods, Go units and new 12-group CLI comparisons; full Linux lifecycle oracle unavailable |
| `setup` | Bash fallback | Not independently proven in Go mode |
| `apply` | Native option validation; Bash operations | New option-boundary comparisons and Go units; full Linux lifecycle suite unavailable |
| `render` | Native option validation; Bash operations | New option-boundary comparisons and Go units; full Linux lifecycle suite unavailable |
| `up` | Native option validation; Bash operations | New option-boundary comparisons and Go units; full Linux lifecycle suite unavailable |
| `down` | Native option validation; Bash operations | New option-boundary comparisons and Go units; full Linux lifecycle suite unavailable |
| `restart` | Native option validation; Bash operations | New option-boundary comparisons and Go units; full Linux lifecycle suite unavailable |
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
| CPU render plan and outbound-peer bounds | Native supported core facts and peer validation; Bash config/hardware collection, callbacks and arithmetic compatibility fallback | Supplementary memory/network comparisons and unchanged render goldens, 8 new methods and Go units; full Linux CLI oracle unavailable |
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
| Config version policy and stamping | Native supported validation/transform and atomic publication with source ownership; Bash warnings/gates, interposed tools, restrictive umasks and compatibility fallback | New 16-method version comparison suite and 7 new publication methods, native success spy and Go units; original Linux version suite unavailable |
| Config migrations | Native supported legacy-worker/XvB and Telegram-control plans/transforms; Bash file I/O, callbacks and compatibility fallback | 14 supplementary migration/static comparisons, 2 protocol tests and Go units; original Linux migration suites unavailable |
| Config credential and CLI appliance-default JSON transforms | Native supported ordered JSON transforms; Bash generation, default-table reads, warnings and appliance-default file I/O with jq fallback | 22 supplementary comparisons/static tests and Go units; original Linux suites unavailable |
| Node RPC credential publication | Native for a fresh fixed stage and standard tools; Bash final chmod, existing-stage handling and compatibility fallback | Supplementary persistence comparisons and 8 new publication methods, native success spy and Go units; Linux secrets/control oracle unavailable |
| Masked config prefill JSON | Native supported ordered transform; Bash validation, file I/O, warnings and worker callbacks with jq fallback | 9 supplementary methods, including 21 paired renders and native/protocol checks; original Linux masking/worker suites unavailable |
| Worker read-credential JSON | Native supported JSON stages; Bash validation, HMAC, warnings and file transactions with jq fallback | 13 supplementary tests, including 25 paired renders and native/protocol checks; original Linux worker-config suite unavailable |
| Config change descriptions and `.env` diff | Native supported messages/flags and byte-order comparisons; callback/locale compatibility fallback | 12 supplementary methods and Go units; original Linux config/approval suites unavailable |
| Payout public-view-key derivation | Native canonical-scalar curve arithmetic; Bash address collection/diagnostics and Python compatibility fallback | 8 supplementary methods and Go units; original Linux payout-wallet-pairs suite unavailable |
| Payout ownership validation | Native supported verdicts with supplied decoded identities; Bash address readers, callbacks and compatibility fallback | New 8-method payout-key comparison, 9 new methods and Go units; original Linux wallet-pair suite unavailable |
| Shared dotenv decoding and file lookup | Native supported decoder and literal-key lookup; Bash file collection, regex matching and compatibility fallback | Unchanged directory line-break suite, 12 supplementary methods and Go units; broader Linux unit-helper suite unavailable |
| Compose project identity | Native supported C/POSIX resolver; Bash file collection, warning callbacks and compatibility fallback | Unchanged 14-assertion ownership suite, supplementary comparisons and Go units; broader Linux/Docker oracle unavailable |
| Remaining typed validation and config-derived values | Bash fallback | Existing sparse-config fixtures pass with Go helpers |
| Dashboard child readiness | Bounded readiness and early-exit detection for the Python child | Delayed/failed startup Go units and unchanged HTTP suites |
| State response generation | One frozen input envelope across hybrid request phases | Forced-interleaving and single-clock regressions, Go transport unit and unchanged state/view suites |
| Dashboard route/method table, security headers and shell/static/preview transport | Native Go server with explicit Python data/control fallback | 19 original HTTP tests plus 15 supplementary comparisons; full 3719-test runs include all 3716 frozen original tests |
| Miner connection, XvB standby and Prometheus routes | Native payload/exposition with Go domain computation and Python config/storage inputs; compatibility fallback | Unchanged route suites and new native-ownership comparisons; full backend remains hybrid |
| `/api/state` history chart | Go projection, gaps and markers; Python filters/downsamples before bounded transport, with native SQLite | Unchanged chart/state suites through adapters, new 86400-row comparisons and Go units |
| Dashboard domain metrics | Go computes state/Prometheus metrics from Python inputs, including five exact history averages; standalone Go averages retained | All 55 unchanged metrics/average tests through the Go adapter, native-ownership guard, compact-path comparisons and Go units |
| History series and headline cards | Native filtering/buckets, payouts, hashrate and cadence; Python business/config inputs, native SQLite | Unchanged series/state suites through the views adapter, comparisons and Go units |
| System/proxy/Tari/sync/Monero presentation | Native five builders; Python raw snapshots and remaining state assembly | Unchanged infrastructure/Monero/location suites, HTTP ownership guard and Go units |
| Worker rows, RigForge display and energy | Native supported snapshots/config inputs in state; Python supplies descriptors | Unchanged view/worker suites through the new fleet adapter, comparisons and Go units; final results below |
| Host-resource availability and capacity | Native bounded forecast and validation; unsupported large capacity operands fall back | Unchanged resource/state/cost suites through the fleet adapter, comparisons and Go units |
| Pool/network, raffle history/eligibility and update filtering | Native supported display inputs; Python supplies the existing native Monero result and running version | 171 unchanged focused tests and new A/B cases; full results below |
| Header status badges | Native ordered badges with supplied metrics, thresholds and locality | Unchanged badge/wallet/header suites and native HTTP ownership guard; wallet KV reading remains Python |
| Remaining state presentation, polling and Tor | Python reference behind Go HTTP routing | Earnings, base metadata, egress/topology derivation and polling remain Python; no complete state proof |
| SQLite engine, open, schema, migrations and recovery | Native Go in the normal Go server child; Python memory state and business SQL construction remain | 343 unchanged focused tests with ported Python paths fatal, existing/legacy/corrupt startup comparisons, Go units and paired full 3719-test suites |
| Control intent envelopes, worker writable keys, request publication and result reads | Native Go helpers in the Go dashboard child; Python config masking, wait I/O and worker HTTP remain; public control policies below | 377 unchanged focused wizard/control tests plus supplementary byte, startup, concurrency and mutation cases; injected UUID/rename hooks listed separately |
| Control HTTP config, preview, commit, upgrade, OS-update, backup and result | Native header/body/approval/version/action policies, pending/completed/error responses and commit predicate; Python async transport, validators and service callbacks | 157 unchanged focused originals with ten original bodies fatal; six new A/B cases, two source mutations and seven failure-path cases; [results](results-control-http.md) |
| Wizard stage, status and read-only spool views | Native Go helpers under Go selection; Python launch and HTTP orchestration remain | Same unchanged focused suites with original ported functions fatal; off-loop state/status coalescing and public reference-selection sentinels |
| Wizard atomic writes, conflict checks, rollback and temporary cleanup | Native Go helpers, including raw archive streaming; Python transport and typed config orchestration remain; rig/restore plans below | 282 unchanged wizard tests through the transaction adapter; injected replace/unlink cases are explicit I/O interpositions; supplementary comparisons and source mutations |
| Wizard config preparation, merge/default stripping, machine names and recovery policy | Native ordered Go transforms; Python supplies runtime schema/defaults and spool reads, retaining input normalization and HTTP sequencing | 334 unchanged focused tests plus 12 new comparison/mutation cases; results below |
| Wizard handoff, acknowledgement, keep-role and retry | Authenticated readiness/status decisions, handoff reads, atomic markers and ordered cleanup native; Python authentication transport, JSON and callback sequencing | 334 unchanged focused tests plus 16 new comparison, mutation and concurrency cases; results below |
| Wizard rig and restore submission | Native validation, ordered publication and archive-placement plans; Python multipart/auth/lock transport and action execution through native atomic writers; typed plans below | 334 unchanged focused tests with replaced original bodies fatal, three new A/B comparisons and two source mutations; results below |
| Wizard typed config submission and preserved-disk shortcut | Native routing, keep/auth/install gates, probe-verdict/publication plans and warnings; Python parsing, runtime providers and probes remain; preparation phases below | 334 unchanged focused tests with original typed handler fatal, ten new A/B comparisons and two source mutations; results below |
| Wizard typed config preparation | Native source/object gates, strict preparation, prior-attempt decision, default preparation/merge and machine-name validation phases; Python JSON, providers, shape guards and phase execution | 334 unchanged focused originals with parent guards, nine new comparisons/failure/selection cases and two source mutations; [results](results-wizard-preparation.md) |
| Wizard defaults, explicit config, inventory and change metadata | Native disk selection, answer merge, materialization, row policy, deduplication and spool deletion; Python lexical normalization, providers and callbacks | 334 unchanged focused tests with all six original bodies fatal, five new A/B cases and two source mutations; [results](results-wizard-values.md) |
| Dashboard raw configuration documents | Native duplicates, placeholders, paths/diagnostics, alias placement and host-error-record refusal; Python standard-library JSON decoder and exception transport | 530 unchanged focused tests through fatal reference guards plus five new A/B cases and two source mutations; [results](results-documents.md) |
| Wizard token gate, form assembly and install validation | Native Go policy and ordered mutation plans; Python HTTP/cookie transport, input normalization and defaults table | 322 unchanged wizard/defaults tests with original policy bodies fatal; byte/order comparisons, Unicode vector and two source mutations |
| Appliance host scripts and container entrypoints | Application ports excluded, owner ruling 2026-11-01 | Reference scripts retained |
| Go shipping docs, release bundle and image builds | Planned after CLI/backend ports; reference fallback required | Not implemented or validated |

## Harness adapters

The [adapter ledger](adapters.md) lists supplementary adapters and reasons, including [wizard/control hooks](results-channel.md#adapters-and-native-proof) [transaction hooks](results-wizard-transactions.md#adapters-and-native-proof) and [policy hooks](results-wizard-policy.md#adapters-and-native-proof).
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

## Dashboard presentation results (2026-11-01)

The fleet/resource and overview/badge slices are preserved in the
[presentation results](results-dashboard-presentation.md). Their full 3716-test
reference and Go runs passed; storage, polling, earnings and launch selection
remained Python. The review follow-up below supersedes their gate status.

## Independent review follow-up (2026-11-01)

The operator's 19:45Z ruling moves G9, G1, G4, G5, G6 and G10 ahead of further
backend work. These six fixes are implemented; exact commands, results, adapters
and intentional compatibility cases are in the [review results](results-review.md).

- G9: fixed branch-added adapter indentation and added a 25-minute reusable Go
  CI job for builds, race units, vet and focused parity. Existing jobs/checks remain.
- G1: the unchanged seven-test parser oracle runs in both modes with recorded
  native statuses; the miner-connection group records native versus reference
  ownership. Isolated source mutants leave the original oracle green and fail
  the new ownership assertions. `make test-go-native-guards` runs these proofs.
- G4: unset, Bash and Python selection ignore native-helper overrides. Native
  fallback carries private hybrid state while preserving the established Bash
  selector contract. Three-mode sentinels and the existing CLI suites pass.
- G5: status retains the first stdout write error and returns 1. Closed stdout
  uses an explicit Bash compatibility path; unwritable open stdout remains Go.
  Closed stderr and read/write `/dev/null` retain their reference behavior.
- G6: Go waits for bounded child readiness and detects early exit before serving.
  Delayed and failed startup cases use a single caller request, without retries.
- G10: state GET captures the complete input envelope, including storage, settings,
  history, metadata and one clock. POST uses that frozen envelope. Forced poll and
  config interleaving, fatal live storage reads and the clock boundary are covered.

The frozen full suites pass in both modes: 3716 unchanged tests plus three new
snapshot tests (3719 total). Python coverage is 97.07% for reference and 86.40%
for Go selection. The patch gate passes at 93% for reference; Go-only patch
coverage fails at 83%, while Go plus overview/fleet A/B append passes at 93%.

These review results preceded the native SQLite slice below. Python still owns
polling, earnings/XvB, wizard/control, business SQL construction and remaining handlers.

## Native SQLite results (2026-11-01)

`go/internal/dashboard/storage/` now owns the SQLite engine, connection settings,
15 application tables, ten indexes, legacy migrations, integrity checks and
corrupt-database quarantine/recovery. `go_storage.py` connects the remaining Python
StateManager logic to the Go helper; the normal Go child installs it before app
construction. Missing bridge support fails before opening a Python database.
Stateless transport fixtures remain an explicitly supported compatibility case.

The [storage results](results-storage.md) list exact commands, adapter hooks,
failure controls and limits. Existing tests and fixtures remain unchanged.

| Check | Reference | Go selection |
|---|---|---|
| Unchanged storage/worker suites | 343 passed | 343 passed with Python connection/schema/recovery paths fatal |
| Full dashboard suite | 3719 passed; 94.53% Python coverage | 3719 passed; 85.04% Python coverage, storage and presentation adapters enabled |
| Patch coverage | 92% passed | Go-only 84% fails; Go plus presentation A/B append 93% passes |
| Additional storage checks | Reference seeds and expected values | Four startup cases and ten bridge cases passed; race units, vet, module verification and CGO-free Linux amd64/arm64 builds pass |

Startup cases use the normal Go command on existing, legacy and corrupt databases
and serve state/miner-connection contracts without caller retries. No polling or
daemon client is started in these fixtures. Native units also cover migration
failure transaction boundaries, literal database filenames and recovery failures.

The reference's second-resolution quarantine naming can overwrite a previous
quarantine on an immediate recovery retry in the same second. Go preserves that
behavior for parity; a correction must change both implementations together.
Python StateManager caches and business methods remain in use; this is not a
complete native storage service or a performance result. Production container
selection and shipping remain unimplemented; later sections record wizard/control slices.

## Operator 20:35Z review follow-up

The first `.env` heredoc is again the original key list: Go publication fallback
uses a cat here-string, preserving interposed-tool behavior. The unchanged redaction selftests pass with selection unset:
39 and 175 assertions, matching the independently materialized starting commit.
GNU topology lint now passes after repairing 111 hits in 23 port-added test files.
No lint exemption or pre-port fixture changed; private-range classifier boundary
cases use semantic address construction rather than losing their input classes.

The production bridge sends filtered/downsampled chart rows and five history
averages; it does not send the complete hashrate history in GET or POST. Go retains the
prepared rows locally during POST and builds the final chart. Direct legacy
fixtures retain their old input protocol, explicitly separate from this path.
Identical overlapping state polls share one collection, with four distinct
collections allowed at once. The last departing caller cancels its collection;
completed results are not cached. Raw query forwarding stays byte-compatible.

The CLI captures inherited ignored signals before Go launch, restores them before
Bash fallback and removes its private marker. Paired SIGPIPE/SIGTERM cases and
an isolated source mutation verify the behavior.

The [later review results](results-review-2035.md) record frozen-start commands,
new versus original evidence, concurrent 86400-row state comparisons and gate
results. In-process stack assertions remain Bash after the harness scrub; the
new lifecycle option comparisons do not prove lifecycle operations in Go.
The following slices add native control protocol, wizard views and transaction files;
wizard auth/HTTP orchestration and production shipping selection remain pending.

The frozen starting dashboard passed 3716 original tests. Current reference and
Go runs each pass 3719 tests (94.46% / 85.44% Python coverage). Reference-only
and Go-only patch coverage fail at 67% / 83%; Go plus A/B comparison append
passes the unchanged gate at 94%. New versus original test counts are explicit
in the later review results.

## Wizard views and transactions

The [channel results](results-channel.md) preserve the views/control slice:
377 unchanged focused tests, 403 with new cases, 3719 in both full arms and a
94% appended patch-coverage pass. Native state/status collection runs off-loop,
shares one in-flight task per app and holds the submission lock for state.

The [transaction results](results-wizard-transactions.md) preserve native atomic
writes, raw archive streaming, conflicts, rollback and temporary cleanup:
282 unchanged wizard tests, 295 with new cases, full 3719-test arms and a 95%
appended patch-coverage pass. Explicit replace/unlink hooks preserve fault tests;
production uses Go syscalls. Auth/form policy is added by the next slice.

## Wizard policy, config and terminal actions

Earlier [auth/form](results-wizard-policy.md), [config/recovery](results-wizard-config.md),
[terminal action](results-wizard-terminal.md), [rig/restore](results-wizard-submission.md),
[typed submission](results-wizard-typed.md), [defaults/metadata](results-wizard-values.md)
and [raw-document](results-documents.md) reports preserve native boundaries,
original-suite A/B passes, mutation controls and separately graded coverage.

The [control HTTP results](results-control-http.md) preserve native policies,
157 original focused tests, fifteen additions, full 3719-test arms, native failure
boundaries and separate/combined coverage. Python retains async I/O, external
validators, masked-config reads, service callbacks and worker-specific HTTP.

The [preparation results](results-wizard-preparation.md) add native typed-config
source/default/name phases, preserving ordered providers and both prior-attempt
reads. Python retains decoding, normalization, callbacks and wizard-state assembly.
Both full arms pass 3719 tests: reference coverage 85.13%, Go 80.02%; the focused target passes 345.
Separate patch coverage is 31%/86%; combined plus focused cases passes at 92%, with the new bridge separately measured at 53/58 executable lines.

## Unavailable and known host constraints

- `make test-stack` deliberately refuses macOS; no Linux suite verdict is claimed.
  The unchanged unit-helper, masking, worker-config and payout-wallet-pairs suites require that harness and remain unproven locally.
  Independently of the host refusal, `tests/stack/lib.sh` scrubs `PITHEAD_IMPL`
  and `PITHEAD_GO_BINARY`. `run.sh`/`env.sh` startup selection does not survive
  that scrub for sourced, in-process assertions. No native Go proof or
  per-fragment call count is claimed from `make test-stack` under Go selection.
- `make test` now passes shell lint and stops at Markdown lint on third-party
  files in the required local uv cache, in both modes. Changed project Markdown
  is checked separately; the original gates remain unchanged.
- The default file-budget comparison against `develop` finds two pre-existing
  version-branch differences: the firstboot wizard ceiling and a
  provision-browser-submit row. The documented starting-SHA override passes; no
  budget entry changed. Both `PITHEAD_IMPL=bash make lint-file-budget
  lint-pithead-build` and `tests/go-parity/run.sh make lint-file-budget
  lint-pithead-build` report that same default-base failure.
- Integration auth-fail-closed assumes GNU `stat`/`chown`; BSD grep also fails
  topology scanner selftests. GNU-first topology checks pass at the frozen start
  and repaired head; the earlier BSD failure did not establish repository parity.
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

1. Finish wizard-state assembly and worker-specific control HTTP/I/O; add production selection and release/dashboard/appliance shipping artifacts with reference fallback.
2. Finish remaining state/earnings and polling contracts; keep native and fallback claims separate.
3. Return to config/render/lifecycle and remaining CLI verbs, starting with `upgrade`, `backup` and `restore`.
4. Resolve G7 status escape bytes and obtain G8 privileged Linux/fleet proof on pushed heads; performance work remains with its separate owner.
