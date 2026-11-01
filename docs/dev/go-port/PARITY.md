STATUS: IN PROGRESS

# Go port parity

Incremental port for issue #3811, based on
`a73ffced33800de9435779a9cabef53864455acb` on branch `go-port/3811`. The owner
authorized implementation on 2026-10-31. Rounds 1–4 are committed at
`4565297a`, host probes at `d9c9d1ff`, verifier/daemon probes at `82d34cfd`,
control/miner probes at `22374d87`, grouped disk checks at `eec3afce`,
data/deployment probes at `a84818dd`, Tor address probes at `af91d3d8`, and
payout-address/config probes at `f74043ae`, network probes at `fef0e656`, and
LAN guard probes at `e1792854`, Docker egress probes at `7a43aa30`, nft/sync-state at `525a359b`, Tor history at `b6ee4093`, container diagnostics at `975161c6`, Monero sync/peer/tip probes at `aa68ca87`, remote RPC preflight at `56f5bcdd`, ZMTP validators at `6f34210a`, stream exchange at `cbfdfbcd`, and raw config validation at `a45c6bb6`.
The operator commits later rounds; Git metadata is read-only. No performance benefit is claimed.

## Scope and continuation criteria

Port the CLI, dashboard backend including the wizard and control channel, then
practical appliance host and container entrypoint code. Preserve Bash/Python as
the reference and fallback, upstream daemons, browser assets, runtime filenames,
database migrations and wire formats. Existing tests, fixtures and checks remain
unchanged.

Each CLI slice must match stdout, stderr, exit status and persistent-file bytes.
The dashboard must retain every HTTP/JSON contract and start on existing and
corrupt databases with the same migration and recovery behavior. A fallback pass
does not prove native Go behavior. `STATUS: COMPLETE` requires every existing
suite runnable locally to pass unchanged under Go selection.

The bench experiment remains outstanding. Measure CLI first-output latency,
apply/upgrade wall time, serial and parallel suite CPU/wall time, module size,
tested functions, mutable globals and lint findings. Measure dashboard idle CPU,
working and peak memory, cold/warm state latency by range/client count, poll
stalls, start/stop time, image size and scan findings at 2/50/100 rigs. Compare
Bash/Go and Python/current, Python/identical algorithm fix, Go/identical algorithm
on one reserved bench with restored state and interleaved repetitions. The
operator must set a performance threshold after measuring the noise floor.

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
| Remaining typed validation and `.env`/Caddyfile render | Bash fallback | Unchanged v2.0.0 `.env` fixture passes with native getters |
| Dashboard routes, state, polling and Tor | Python reference | Baseline suites pass; Go backend not ported |
| SQLite schema, migrations and recovery | Python reference | Baseline suites pass; Go backend not ported |
| Wizard launch and control channel | Bash/Python reference | Not ported |
| Appliance host scripts and container entrypoints | Reference scripts | Not ported |

The native doctor packages retain check IDs, severities, messages and surface
wording. Unsupported arithmetic, NUL output, marker read failures and unusual tool launches return
`ErrUnsupportedProbeInput` so the future collector can fall back safely. Darwin
CPU detection preserves the original pipefail/SIGPIPE pipeline behavior. Executable
text without a shebang returns unsupported rather than a boot verdict, preserving
the future Bash fallback boundary. Doctor
JSON preserves order, nullable malformed TSV fields, jq string encoding, summary
counts, abrupt-exit refusal, signal forwarding and temporary-file cleanup.

## Harness adapters

Only new files under `tests/go-parity/` adapt unchanged suites or supply parity
oracles:

- `env.sh` restores Go selection and the binary path after the unchanged shell
  harness clears `PITHEAD_*`; `run.sh` invokes an unchanged command with that hook.
- `test_cli.py` compares generated entrypoints in synthetic installs, including
  aliases, chains, fd 9, signals, SIGPIPE and proof that native help/version do
  not execute Bash.
- `test_status.py` and `status_fixture.py` provide synthetic engine, curl and
  OpenSSL behavior without contacting a daemon or dashboard.
- `test_doctor.py` and `doctor_fixture.sh` replace only probe collection in a
  temporary generated CLI, retaining its dispatcher and Bash JSON oracle.
- `doctor_memory_reference.sh` extracts guarded free-RAM and clock verdict blocks
  and substitutes controlled meminfo because existing tests source Bash.
- `doctor_verification_reference.sh` invokes the unchanged release-verification
  function and extracts the guarded daemon verdict block. New tagged tests use
  disposable installs and fake engines because the existing doctor suite sources
  Bash functions. They compare exact TSV/human bytes and engine calls, without a
  daemon, network, image pull or verification container.
- `doctor_control_reference.sh` invokes unchanged control-unit and local-miner
  functions with supplied getter outputs, synthetic unit files and isolated tools.
  The original tests source Bash functions; this adapter reaches native packages
  without changing those tests or executing systemctl. Environment/config parsing
  remains in Bash.
- `doctor_host_reference.sh` extracts guarded dependency, boot and CPU verdict
  blocks. It uses controlled CPU files and isolated fake host tools because the
  existing source tests cannot reach Go packages. No real engine, systemd, sysctl,
  network or host probe runs.
- `doctor_disk_reference.sh` invokes unchanged disk-budget, mount-resolution and
  grouped-check functions against fake df responses. Existing tests source Bash;
  this adapter compares native findings and df calls without host disk probes.
- `doctor_data_directories_reference.sh` invokes the unchanged missing-directory
  functions and extracts guarded doctor/deployment verdict blocks. Getter outputs
  and disposable filesystem fixtures reach native packages without changing the
  source-based tests; dotenv parsing remains in Bash.
- `doctor_onion_reference.sh` extracts the guarded address-report block and calls
  the original address helpers. Getter outputs and program names reach native
  probes without changing source tests or contacting Tor; a guard prevents the
  supplied program name from turning source loading into a CLI launch.
- `doctor_config_reference.sh` extracts the guarded config-diagnostics block and
  calls the unchanged payout-address classifiers. Supplied jq/variant outputs,
  public vectors and isolated Python availability reach native packages without
  changing source tests. JSON parsing and variant-file reading remain Bash.
- `doctor_network_reference.sh` calls unchanged IP, stratum and Tor checks with
  supplied getter outputs and isolated tools. It compares native findings,
  setup warnings and command arguments without changing source tests or using
  real interfaces, listeners, containers or network requests.
- `doctor_lan_reference.sh` calls unchanged LAN readback, boot applicability,
  publishing and report functions with supplied bind getters and isolated tools.
  Existing tests source Bash; this adapter compares native verdicts, exact report
  bytes and command arguments without invoking a host firewall, engine or systemd.
  Report calls retain the dispatcher's conditional context for Bash `errexit`.
- `doctor_egress_reference.sh` calls unchanged Tor token/CIDR helpers, rules,
  readback and doctor reports. Config getters and active sync IPs are supplied
  because the source-based suites cannot reach Go packages. Its formatter-only
  operation substitutes a readback status to compare both backend/surface message
  mappings; separate readback tests use the unchanged Bash verifier and fake tools.
- `tor_sync_reference.sh` invokes the unchanged sync-IP selector with supplied
  config/state-dir getters and disposable markers. Existing suites source Bash;
  this adapter compares native selection without changing those suites or reading
  live stack state.

- `tor_history_reference.sh` calls the original history/control predicates with
  supplied time/config/mount values and fake tools. Its lock/result/audit hooks
  isolate the pure outage transition and preserve record bytes without touching
  stack state; the existing source-based tests cannot invoke native packages.

- `doctor_containers_reference.sh` calls unchanged restart and revenue checks
  using fake engines/sleep and a supplied migration hold. Source-based suites
  cannot invoke native packages; this compares findings and exact tool arguments.

- `doctor_monero_reference.sh` calls unchanged sync/peer/tip functions with
  supplied RPC getters/time, synthetic credentials and fake engines/curl. Existing
  source-based tests cannot invoke Go packages; this compares exact findings,
  authentication arguments and call order without an RPC server or container.

- `node_monero_reference.sh` extracts unchanged `monero_rpc_speaks` with a synthetic
  config and fake timeout/curl so the CLI's readonly cap does not override fixtures.
  Source-based suites cannot invoke native packages; it compares reason/exit
  status, command arguments and stdin credential bytes.

- `node_zmq_reference.sh` extracts unchanged greeting/READY/endpoint functions.
  Source-based suites cannot invoke Go packages; a fake timeout supplies reply
  bytes/status without running the endpoint's TCP shell command. It compares
  predicate and reason bytes, retaining exposed arithmetic/NUL diagnostics.

- `node_zmq_exchange_reference.sh` runs the unchanged endpoint function with its
  sole TCP opener replaced by a guarded inherited-descriptor check. Local socket
  pairs exercise actual Bash reads/writes and the five-second timeout without a
  network connection; source-based suites cannot invoke the Go exchange.

- `config_document_reference.sh` calls the unchanged embedded Python parser in
  Bash mode; `test_config_document.py` proves native selection through CLI fallback.
  The unchanged parser suite also reaches Go.

- `config_defaults_reference.sh` supplies platform/table/config fixtures to the
  Bash helpers. `test_config_defaults.py` proves native wiring and invokes the
  unchanged render fixture; existing shell suites remain guarded on macOS.

- `config_validation_reference.sh` supplies disposable config documents to the
  original validators. `test_config_validation.py` compares exact diagnostics and
  statuses, proves native selection without jq and checks compatibility fallback.
  Existing source-based suites and their fixtures remain unchanged.

Sourcing Bash functions alone does not establish native behavior. Native slices
use tagged comparisons or helper/wiring checks that prove Go execution. Current
targets are `test-go-parity`, `test-go-status-parity`,
`test-go-doctor-parity`, `test-go-doctor-memory-parity`,
`test-go-doctor-host-parity`, `test-go-doctor-verification-parity`,
`test-go-doctor-control-parity`, `test-go-doctor-disk-parity` and
`test-go-doctor-data-parity`, `test-go-doctor-onion-parity` and
`test-go-doctor-config-parity`, `test-go-doctor-network-parity` and
`test-go-doctor-lan-parity`, `test-go-doctor-egress-parity` and
`test-go-doctor-nft-parity`, `test-go-doctor-history-parity` and
`test-go-doctor-containers-parity`, `test-go-doctor-monero-parity` and
`test-go-node-monero-parity`, `test-go-node-zmq-parity` and
`test-go-node-zmq-exchange-parity`, `test-go-config-document-parity` and
`test-go-config-defaults-parity` and `test-go-config-validation-parity`.

## Earlier slice results

Detailed paired commands, results and limits are preserved in
[baseline and early results](results-baseline.md), [CLI probe results](results-cli-probes.md) and
[network and firewall results](results-network-probes.md), plus
[remote-node probe results](results-node-probes.md) and
[configuration results](results-config.md).

## Typed config validation slice (2026-10-31)

Native validators cover worker endpoint descriptors and duplicate-name warnings,
energy settings, webhook member types and recursive control-character checks.
The Bash callers preserve validation order and diagnostic formatting. The private
helper returns pass, error, warning or unsupported; unsupported documents and
jq-specific cases retain the original validator. Normal native cases do not
launch jq. Config migrations, the remaining typed checks and the
`.env`/Caddyfile renderers remain Bash.

The new 11-test suite compares 227 generated cases, 14 compatibility cases,
native jq-bypass checks for all four sections and CLI fallback-marker wiring.
Direct helper checks cover error/warning statuses and silent unsupported results.
C0/DEL/C1 values, control-bearing keys, numeric precision/underflow and
version-sensitive fleet-port literals are included. Existing tests and fixtures
remain unchanged. Private records use `.go-cache/logs/config-validation-*`.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with the local cache variables
listed above and an absent Docker socket.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-validation-parity` | PASS, 11 tests and Go units | Same result |
| `make test-go-config-defaults-parity test-go-config-document-parity test-go-parity` | PASS, defaults/raw-parser/CLI comparisons, unchanged parser and render fixtures, Go units | Same result |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` | FAIL, existing `config_defaults_reference.sh` case indentation, pinned shfmt, exit 2 | Same failure; ShellCheck passes |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML PASS; Markdown FAIL, 22 third-party cache findings, exit 2 | Same result |
| `make test-stack`; `bash tests/stack/standalone/test_config_defaults.sh` | macOS refusal, exit 2 / 1 | Same refusal; no bypass |

The previous adapter is now tracked and included in the existing shfmt gate;
its case indentation was not included while it was untracked in the preceding
round. It remains unchanged under the test-preservation rule. The new adapter
passes pinned ShellCheck and shfmt checks explicitly.

After `make go-build`, native checks pass with worktree cache/temp paths:
`go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead`
(compilation only). Go formatting, Ruff and `git diff --check` pass.
An initial `go test ./...` with an unnormalized `go/../.go-cache/tmp`
`TMPDIR` hit existing Darwin symlink assertions; canonical cache/temp paths pass.
Source/security reviews found no remaining issues. Scoped Markdown is checked
with the existing configuration:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-config.md
```

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
- Compose/Caddy parsing, container/image tests, mini-stack, KVM and live matrices
  require Docker, Linux, a reserved bench or hardware. No Docker daemon, bench or
  LAN host was contacted.
- Bench measurements, image scans/sizes and acceptance ADRs remain outstanding;
  local test duration is not benchmark evidence.

The local CLI-only graph used for navigation covers 96 files, 825 nodes and 1099
edges. Its 14 collapsed relation pairs and tool/skill version mismatch make it a
partial navigation aid, not parity evidence.

## Next

The operator parked doctor and Tor/ZMTP probes on 2026-10-31. Next, in order:

1. Finish typed validation and port byte-identical `.env`/Caddyfile rendering.
2. Port `render`, `apply`, `up`, `down` and `restart` using that config layer.
3. Implement dashboard routes, HTTP/JSON, state/polling, SQLite migrations/recovery and the container switch.
4. Port `upgrade`, `backup` and `restore`.
5. Run unchanged Linux/Docker suites and the reserved-bench experiment on the operator's infrastructure.
