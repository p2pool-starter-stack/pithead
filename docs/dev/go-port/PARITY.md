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
| `setup` | Bash fallback | Not independently proven in Go mode |
| `apply` | Bash fallback | Not independently proven in Go mode |
| `render` | Bash fallback | Not independently proven in Go mode |
| `up` | Bash fallback | Not independently proven in Go mode |
| `down` | Bash fallback | Not independently proven in Go mode |
| `restart` | Bash fallback | Not independently proven in Go mode |
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
| Config defaults, materialization and getters | Native with runtime table; jq compatibility fallback | 5 tagged groups / 744 scenarios and wiring/render-fixture tests |
| Worker, energy, webhook and control-character validation | Native Go-selected validators; jq compatibility fallback | Paired validator corpus and wiring checks; Go units |
| Stratum bind and port parsing | Native for supported settings; Bash compatibility fallback | Unchanged 14-test stratum preflight and render fixture; supplementary byte/status/state comparisons and Go units; full Linux suite unavailable |
| Caddyfile serialization, site URLs, bind plan and auth preparation | Native fragments, site/port formatting, bind filter, auth blocks and boot digest; Bash bind-candidate public-IP checks, discovery, bcrypt, certificate minting and writes; compatibility fallback | Supplementary Caddy/host/port comparisons and Go units; Linux/Docker oracle unavailable |
| `.env` serialization | Native bulk formatter with Bash derivation/writes and compatibility fallback | Unchanged render fixture/goldens pass in Go mode; full Linux suite unavailable |
| Daemon network render plan | Native for supported config; Bash hardware/error handling and compatibility fallback | Unchanged render fixture/goldens and supplementary whole-render comparisons |
| Dashboard-facing CLI render values | Native supported scalar/default/worker-token plan; Bash compatibility fallback | Unchanged render fixture/goldens and supplementary whole-render comparisons |
| Memory render settings and auto ceiling | Native for supported settings/facts; Bash discovery and compatibility fallback | Unchanged render fixture/goldens and supplementary hardware-boundary comparisons |
| Data-directory derivation | Native supported paths/shared-root/default flag; Bash safety checks and compatibility fallback | Supplementary path/state/guard/trap comparisons and unchanged render fixture/goldens; full Linux CLI oracle unavailable |
| Dashboard auth shape and onion/control policy | Native supported credentials/policy; Bash hash reconciliation, warnings and compatibility fallback | Supplementary byte/status/state/order comparisons and unchanged render fixture/goldens; full Linux/Docker auth oracle unavailable |
| Dashboard access settings | Native supported host/port/flag/timezone parsing; Bash host-timezone discovery/default insertion and compatibility fallback | Supplementary byte/status/state/trap comparisons and unchanged render fixture/goldens; full Linux suite unavailable |
| Proxy password, TLS and donation settings | Native explicit/empty settings; auto and unsupported inputs use Bash fallback | Supplementary byte/status/state comparisons and unchanged render fixture/goldens; full Linux suite unavailable |
| Network settings, remote endpoints and pool validation | Native for supported settings; Bash compatibility fallback | Supplementary byte/status/state comparisons and unchanged render fixture/goldens; full Linux suite unavailable |
| Shared Caddy/certificate site names and SANs | Native supported auto-expansion/filtering and SAN formatting; Bash selection/discovery/shell expansion and compatibility fallback | Supplementary comparisons and complete Caddy renders; full Linux/Docker oracle unavailable |
| SSH policy and Monero RPC credential parsing | Native supported SSH validation, password projection and generation plan; Bash username projection, discovery, generation/persistence/log callbacks and compatibility fallback | Supplementary comparisons and unchanged render fixture; original Linux appliance/control oracle unavailable |
| Required wallet fields and Tari mode | Native supported scalar/required/whitespace gates; Bash mode getter, classifiers and compatibility fallback | Supplementary partial-state/callback comparisons and unchanged render fixtures; full Linux CLI oracle unavailable |
| Payout-confirmation scalar config and restore bounds | Native supported settings; Bash time read, wallet-ownership/curve checks and compatibility fallback | Supplementary comparisons and unchanged render fixture/goldens; full Linux CLI oracle unavailable |
| Config version policy and stamping | Native supported validation/policy/ordered JSON transform; Bash file I/O, warnings and compatibility fallback | 16 supplementary comparison tests and Go units; original Linux version suite unavailable |
| Config migrations | Native supported legacy-worker/XvB and Telegram-control plans/transforms; Bash file I/O, callbacks and compatibility fallback | 14 supplementary migration/static comparisons, 2 protocol tests and Go units; original Linux migration suites unavailable |
| Config credential write-back and CLI appliance defaults | Native supported ordered JSON transforms; Bash generation, default-table reads, warnings and file I/O with jq fallback | 22 supplementary comparisons/static tests and Go units; original Linux suites unavailable |
| Remaining typed validation and config-derived values | Bash fallback | Existing sparse-config fixtures pass with Go helpers |
| Dashboard routes, state, polling and Tor | Python reference | Baseline suites pass; Go backend not ported |
| SQLite schema, migrations and recovery | Python reference | Baseline suites pass; Go backend not ported |
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
[later render results](results-render-followup.md).

## Config persistence slice (2026-11-01)

Go renders supported RPC credential write-back and CLI appliance-default JSON.
Bash retains password generation, dry-run decisions, default-table reads, warnings,
file creation, permissions and promotion. Unsupported JSON uses the original jq
fallback. Credential write-back skips dry-run value 1; appliance-default writes
retain their original behavior under that flag. Source/target aliases use jq
fallback to preserve its truncation-before-read behavior, including the existing
version, worker and Telegram writers. The appliance-default function
remains CLI code; host scripts stay excluded.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline and
`tests/go-parity/run.sh` for Go, with worktree caches and an absent Docker socket.
Final records use `.go-cache/logs/config-persistence-final-*`. Earlier runs remain
under `.go-cache/logs/config-persistence-*` and `.go-cache/logs/config-persistence-initial/`;
final reruns below include the shared linked-target guards.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-persistence-parity` | PASS, 22 supplementary comparison/static tests and Go units | Same result; supported native transforms verified without jq |
| Additional config/render comparisons below | PASS, including unchanged raw parser and render fixture/goldens | Same result; native helpers covered separately |
| `make test-dashboard test-fakes test-patch-coverage` with `COMPARE=a73ffced33800de9435779a9cabef53864455acb` | PASS, 3716 dashboard/54 fake tests, 97.42% coverage; patch check not applicable | Same counts; Python backend |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` | PASS, structural/documentation gates and 891 frontend tests | Same result |
| `make test` | FAIL, existing `config_defaults_reference.sh` indentation, pinned shfmt, exit 2; ShellCheck PASS | Same failure and ShellCheck result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python, JS and YAML pass; Markdown fails on 22 findings in third-party uv-cache files, exit 2 | Same result |

Additional config/render command: `make test-go-config-validation-parity test-go-config-defaults-parity test-go-config-document-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-network-settings-parity test-go-stratum-parity test-go-proxy-settings-parity test-go-dashboard-access-parity test-go-dashboard-auth-parity test-go-directories-parity test-go-caddy-bind-parity test-go-payout-settings-parity test-go-wallet-settings-parity test-go-site-names-parity test-go-config-access-parity test-go-config-version-parity test-go-config-migrations-parity test-go-caddy-auth-parity test-go-caddy-parity test-go-caddy-sites-parity test-go-parity`.
Native checks PASS: `go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compile only).
Source review, Go formatting, changed-shell shfmt, generated CLI/new-adapter ShellCheck and new Python Ruff checks PASS.
Scoped Markdown PASS: `npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/adapters.md docs/dev/go-port/results-render-followup.md`.

Security review found no new critical, high or medium findings. The reference credential
writer reuses `${CONFIG_FILE}.tmp`: a pre-existing permissive file keeps its mode
during the rewrite, until the final chmod. That inherited risk of exposing credentials
is retained for parity; the normal newly created temp remains owner-only.

## Unavailable and known host constraints

- `make test-stack` deliberately refuses macOS; no Linux suite verdict is claimed.
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

Doctor and Tor/ZMTP probes remain parked. The owner narrowed scope to the CLI
and dashboard application code on 2026-11-01; shipping integration follows those
ports. Next, in order:

1. Finish config persistence and parser orchestration. Obtain unchanged Linux CLI and Docker parser verdicts.
2. Port `render`, `apply`, `up`, `down` and `restart` using that config layer.
3. Implement dashboard routes, HTTP/JSON, state/polling, wizard/control, SQLite migrations/recovery and the container switch.
4. Port the remaining CLI verbs, starting with `upgrade`, `backup` and `restore`.
5. Update shipping documentation, release bundles, dashboard images and appliance image builds with reference fallback.
6. Obtain Go-enabled fleet proof on pushed heads; keep performance work with its separate owner.
