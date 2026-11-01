STATUS: IN PROGRESS

# Go port parity

Incremental port for issue #3811, based on
`a73ffced33800de9435779a9cabef53864455acb` on branch `go-port/3811`. The owner
authorized implementation on 2026-10-31. Rounds 1–4 are committed at
`4565297a`, host probes at `d9c9d1ff`, verifier/daemon probes at `82d34cfd`,
control/miner probes at `22374d87`, grouped disk checks at `eec3afce`,
data/deployment probes at `a84818dd`, Tor address probes at `af91d3d8`, and
payout-address/config probes at `f74043ae`, network probes at `fef0e656`, and
LAN guard probes at `e1792854`.
The operator commits later rounds because
this sandbox cannot write shared Git metadata. No performance benefit is claimed.

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
| Docker Tor egress readback and doctor report | Native packages with supplied config/sync state; Bash collector and nft fallback | 18 tagged groups and Go units |
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
| Config parse/validate/render, `.env`, Caddyfile | Bash fallback | Not ported |
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

The adapters do not establish native behavior for sourced Bash functions. Every
native package slice therefore has a separate tagged comparison suite. Current
targets are `test-go-parity`, `test-go-status-parity`,
`test-go-doctor-parity`, `test-go-doctor-memory-parity`,
`test-go-doctor-host-parity`, `test-go-doctor-verification-parity`,
`test-go-doctor-control-parity`, `test-go-doctor-disk-parity` and
`test-go-doctor-data-parity`, `test-go-doctor-onion-parity` and
`test-go-doctor-config-parity`, `test-go-doctor-network-parity` and
`test-go-doctor-lan-parity` and `test-go-doctor-egress-parity`.

## Consolidated results (2026-10-31)

Commands used worktree-local caches. Raw logs and status records remain ignored
under `.go-cache/logs/`. The operator provided the Python 3.11 runtime environment
at `dashboard/.venv`; the host-probe round installed its 18 locked test and 11 locked
development packages. Tool downloads also populated the local caches for
Biome 2.5.0, yamllint 1.38.0 and npm package `@taplo/cli@0.7.0`. No application
runtime dependencies were downloaded by the port. Tests used `UV_OFFLINE=1`,
`UV_PYTHON_DOWNLOADS=never` and `npm_config_offline=true` after tool installation.
`UV_TOOL_DIR` and `UV_TOOL_BIN_DIR` also point inside `.uv-cache/`.

| Suite | Bash/Python baseline | Go-selected result |
|---|---|---|
| CLI scaffold | Reference arm in synthetic installs | `make test-go-parity`: PASS, 12 paired groups plus Go units |
| Native status | Reference arm in synthetic installs | `make test-go-status-parity`: PASS, 9 paired groups including terminal colors |
| Doctor JSON | Reference formatter in synthetic installs | `make test-go-doctor-parity`: PASS, 13 paired groups plus Go units |
| Doctor memory/clock | `PITHEAD_IMPL=bash make test-go-doctor-memory-parity`: PASS | `tests/go-parity/run.sh make test-go-doctor-memory-parity`: PASS; 11 memory/clock and 9 host groups plus Go units |
| Doctor host/dependencies | `PITHEAD_IMPL=bash make test-go-doctor-host-parity`: PASS | `tests/go-parity/run.sh make test-go-doctor-host-parity`: PASS, 9 tagged groups plus Go units |
| Unchanged doctor JSON contract | `PITHEAD_IMPL=bash python3 tests/stack/doctor/test-json-contract.py`: PASS, 2 tests | `tests/go-parity/run.sh python3 tests/stack/doctor/test-json-contract.py`: PASS, 2 tests; sources Bash |
| Pinned doctor IDs | `PITHEAD_IMPL=bash python3 tests/stack/doctor/check-ids.py .`: PASS | `tests/go-parity/run.sh python3 tests/stack/doctor/check-ids.py .`: PASS; source catalog only |
| Dashboard | `env PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests, 97.42% coverage | `tests/go-parity/run.sh make test-dashboard`: PASS, 3716 tests, 97.42%; backend remains Python |
| Fake daemons | `env PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests; backend remains Python |
| Dashboard patch coverage | `env PITHEAD_IMPL=python COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage`: PASS, not applicable because no Python changes were measured | `env COMPARE=a73ffced33800de9435779a9cabef53864455acb tests/go-parity/run.sh make test-patch-coverage`: same result |
| Frontend | `PITHEAD_IMPL=bash make test-frontend`: PASS, 891/891 | `tests/go-parity/run.sh make test-frontend`: PASS, 891/891 |
| Portable tools | `PITHEAD_IMPL=bash make test-tools`: PASS | `tests/go-parity/run.sh make test-tools`: PASS |
| Netwatch/tool installer | `PITHEAD_IMPL=bash make test-netwatch`: PASS | `tests/go-parity/run.sh make test-netwatch`: PASS |
| Restart observer | `PITHEAD_IMPL=bash bash tests/os/selftest-container-restarts.sh`: PASS | `tests/go-parity/run.sh bash tests/os/selftest-container-restarts.sh`: PASS; sources Bash |
| File budget/build guards | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb PITHEAD_IMPL=bash make lint-file-budget lint-pithead-build`: PASS | Same base with `tests/go-parity/run.sh make lint-file-budget lint-pithead-build`: PASS |
| Documentation lint | `PITHEAD_IMPL=bash make lint-docs-voice lint-path-references lint-operator-strings`: PASS | `tests/go-parity/run.sh make lint-docs-voice lint-path-references lint-operator-strings`: PASS |
| Markdown | `npm_config_cache="$PWD/.go-cache/npm" PITHEAD_IMPL=bash make lint-md`: FAIL, 22 third-party cache findings | Same cache with `tests/go-parity/run.sh make lint-md`: same FAIL; both passed before installing test/development tools |
| Changed Markdown only | `PITHEAD_IMPL=bash npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs docs/dev/go-port/PARITY.md docs/dev/repo-map.md`: PASS | Same command with `PITHEAD_IMPL=go`: PASS; existing rules, two explicit files |
| Ruff | `PITHEAD_IMPL=bash make lint-py`: PASS, 574 files formatted | `tests/go-parity/run.sh make lint-py`: PASS, 574 files formatted; prior standalone `.uv-cache/bin/ruff check .` and `format --check .` also passed in both modes |
| Integration selftests | `PITHEAD_IMPL=bash make test-integration-selftest`: FAIL on BSD utility assumptions, 15 passed/11 failed | `tests/go-parity/run.sh make test-integration-selftest`: same result |
| Shell CLI suite | `PITHEAD_IMPL=bash make test-stack`: macOS refusal, exit 2 | `tests/go-parity/run.sh make test-stack`: same refusal |
| Topology lint | `PITHEAD_IMPL=bash make lint-topology`: FAIL in BSD-host selftests | `tests/go-parity/run.sh make lint-topology`: same result |
| Full local gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS; Markdown stops on 22 third-party cache findings (exit 2) | `tests/go-parity/run.sh make test`: same result (exit 2) |

Full-gate commands set `DOCKER_HOST` to an absent socket inside `.go-cache/`
and npm's cache to `.go-cache/npm`; no Docker target was reached. Earlier
attempts stopped at uncached Biome or uv's default tool directory; local tool
installation and `UV_TOOL_DIR` resolved those setup failures. The unchanged
Markdown glob includes cached diff-cover templates and virtualenv license files
under `.uv-cache/`. No lint rule, Make check or cached tool content was changed
to suppress these findings.

The host-probe round reran all native comparison targets, the unchanged doctor contracts,
restart observer, dashboard/fakes, Go race/vet/build checks and affected lints.
Frontend, portable tools, netwatch and integration selftest rows retain evidence
from rounds 1–4. Those rounds also supply default-budget and topology evidence.
Current command records use the `host-` prefix under `.go-cache/logs/`; earlier rounds use `status-`, `doctor-` and `memory-`.

Additional passing checks with local caches:

```bash
make test-go
go -C go test -race ./internal/status
go -C go test -race ./internal/doctor
go -C go test -tags=parity -race -count=1 ./internal/doctor ./internal/host ./internal/status
go -C go vet ./...
go -C go vet -tags=parity ./...
GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead
```

Independent review found the no-shebang launch mismatch; the error boundary and
new regression cases now cover it. Re-review found no remaining defects.
The adapter scripts pass `bash -n`,
ShellCheck 0.11.0 and shfmt 3.13.1; Go formatting and `git diff --check` pass.
The Linux build is compilation evidence, not a Linux runtime result. Pinned Ruff 0.17.0 and markdownlint-cli2 0.18.1 were
installed in local tool caches. Before the operator supplied the Python
environment, `PITHEAD_IMPL=bash make test` and
`tests/go-parity/run.sh make test` passed shell lint and stopped while resolving
locked grpcio 1.84.0/Pygments 2.20.0. The current dashboard and fake-daemon
results above supersede that blocker.

## Verifier and daemon availability slice (2026-10-31)

`go/internal/doctor/release.go` ports the release-verification diagnostic: source
checkout detection, public-key presence, Docker availability, and cached verifier
image findings. It preserves regular-file and symlink behavior and checks Docker
regardless of the selected engine. It never runs the verifier or pulls an image.
`go/internal/doctor/daemon.go` ports Docker/Podman reachability, including missing
Docker's info finding, engine precedence and appliance wording.

These are native package ports; the production doctor collector still executes
Bash. Unsupported shell-script launches and relative executable discovery return
`ErrUnsupportedProbeInput` without a finding. The first new comparison exposed
that `exec.LookPath` searches before `Cmd.Dir` takes effect; release probing now
declines relative PATH entries after its source/no-key short circuits. The new
adapter's source boundaries are checked so an upstream edit fails the test.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Verifier/daemon findings | `PITHEAD_IMPL=bash make test-go-doctor-verification-parity`: PASS, 4 paired groups plus Go units | `tests/go-parity/run.sh make test-go-doctor-verification-parity`: PASS, same groups and units |
| CLI and doctor JSON regressions | `PITHEAD_IMPL=bash make test-go-doctor-parity test-go-parity`: PASS, 13 + 12 paired groups | `tests/go-parity/run.sh make test-go-doctor-parity test-go-parity`: PASS, same groups |

The other consolidated checks reran with the same results; commands are recorded
above and each arm's private logs are identified below.

The consolidated Go race, tagged vet and Linux build commands pass (24 tagged
comparison groups plus units). Adapter syntax, pinned ShellCheck/shfmt and scoped
Markdown checks pass. Independent static review found no remaining defects.
The unchanged shell-suite commands still refuse macOS (exit 2). Private command
and exit records use `.go-cache/logs/verification-*`. Existing tests/checks remain
unchanged; no download, Git write or live probe occurred.

## Control-unit and local-miner slice (2026-10-31)

`go/internal/doctor/control.go` ports unit-directory selection, owner extraction
and the control-channel finding. It compares physical install paths, preserves
missing owner suffixes, distinguishes missing units and foreign spools, and keeps
the superseded rollback-directory guard. It discovers systemctl without executing
it. `go/internal/doctor/local_miner.go` ports the appliance's reduced-HugePages
warning using the existing reservation parser. Getter values are inputs; general
`.env` and config parsing and production collection still use Bash.

The paired cases cover section headings, exact TSV/human findings, appliance
wording, bool normalization, symlink/current/versioned paths, deleted owners,
custom egress units, marker tiers and silent gates. Parent-directory components,
multiline paths, relative executable lookup, sed metacharacters and NUL inputs
decline a native verdict. Safe relative unit directories resolve from the install.
Comparisons exposed Bash's trailing-newline trimming and NUL stripping warning;
the checked marker parser now returns unsupported on NUL lines so memory and
local-miner collection can preserve the Bash diagnostic through fallback.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Control units and miner gate | `PITHEAD_IMPL=bash make test-go-doctor-control-parity`: PASS, 9 tagged groups plus Go units | `tests/go-parity/run.sh make test-go-doctor-control-parity`: PASS |
| File budget, build guards, docs voice, paths and operator strings | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb PITHEAD_IMPL=bash make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings`: PASS | Same base with `tests/go-parity/run.sh make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings`: PASS |

The other consolidated checks reran with the same results; commands are recorded
above and each arm's private logs are identified below.

The consolidated Go race, tagged vet and Linux build commands pass (33 tagged
comparison groups plus units). Adapter syntax, pinned ShellCheck/shfmt and scoped
Markdown checks pass. Independent static review found no remaining defects.
The shell suite still refuses macOS in both modes. Private command/exit records
use `.go-cache/logs/control-*`. Existing tests/checks remain unchanged; no download,
Git write, systemd call, Docker daemon or bench was used.

## Grouped disk slice (2026-10-31)

`go/internal/doctor/disk.go` ports component budgets, nearest-existing-ancestor
resolution and per-filesystem grouping shared by doctor and setup preflight.
It preserves component order, remote-component omission, the 528 GiB combined
budget, unknown-capacity behavior and preflight's warning-only output. Env/config
getters and production callers still use Bash. Relative data paths resolve from
the supplied install directory. Unsupported path/tool inputs and failed capacity
reads decline a native verdict so a future collector can retain Bash behavior.
Go retains df, awk and dirname calls to preserve their output and failure paths.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Disk, CLI and doctor JSON | `PITHEAD_IMPL=bash make test-go-doctor-disk-parity test-go-doctor-parity test-go-parity`: PASS, 8 disk + 13 JSON + 12 CLI groups and Go units | `tests/go-parity/run.sh make test-go-doctor-disk-parity test-go-doctor-parity test-go-parity`: PASS |

The other consolidated checks reran with the same results; commands are recorded
above and each arm's private logs are identified below.

The consolidated Go race, tagged vet and Linux build commands pass (41 tagged
comparison groups plus units). Adapter syntax, pinned ShellCheck/shfmt and scoped
Markdown checks pass. The integer parser now matches Bash's ASCII whitespace
handling. Independent static review found no remaining defects. Final parity logs
use `.go-cache/logs/storage-final-parity-*`, race/vet/build use `storage-reviewed-*`,
and other command/exit records use `storage-*`. Existing tests/checks remain
unchanged; no Git write, download, live disk probe or daemon contact occurred.

## Missing-data and deployment slice (2026-10-31)

`data_directories.go` ports missing-data enumeration, doctor findings and the
relocated-install warning bodies. `deployment.go` ports environment-file and
setup-completion findings. Both preserve literal `true` gating, getter newline
trimming, variable order, symlinks, relative paths and DIY/appliance wording.
Inputs are getter outputs; dotenv parsing and production callers remain Bash.
Unsupported paths/NUL values and warning escapes decline a native verdict.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Data/deployment, CLI and JSON | `PITHEAD_IMPL=bash make test-go-doctor-data-parity test-go-doctor-parity test-go-parity`: PASS, 8 + 13 + 12 paired groups and Go units | `tests/go-parity/run.sh make test-go-doctor-data-parity test-go-doctor-parity test-go-parity`: PASS |

The other consolidated commands reran with the same results.

Additional checks pass: `go -C go test -tags=parity -race -count=1 ./internal/doctor`
(49 tagged comparison groups plus units), `go -C go vet -tags=parity ./...` and
the Linux build command above. Cross-compilation provides no Linux runtime
verdict. New adapter syntax, pinned ShellCheck/shfmt, scoped Markdown and Go
formatting checks pass. Independent static review found no remaining defects.
Current private command/exit records use `.go-cache/logs/stale-*`.
The first Go full gate also caught an extra ledger blank line; it was corrected
before the rerun recorded as `stale-gate-final-go`.
Existing tests, fixtures, goldens, lint rules and Make checks remain unchanged;
no Git write, download, live probe or daemon contact occurred.

## Tor address slice (2026-10-31)

`go/internal/doctor/onion_addresses.go` ports the ordered node/dashboard report,
exact profile gates, placeholder handling and key-specific appliance remedies.
`go/internal/onion/` shares missing-address detection and dashboard text with native
status while preserving its getter order. Getter outputs are inputs; doctor
collection and dotenv parsing remain Bash. No address validation was added.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Tor addresses, status, JSON and CLI | `PITHEAD_IMPL=bash make test-go-doctor-onion-parity test-go-status-parity test-go-doctor-parity test-go-parity`: PASS, 8 + 9 + 13 + 12 paired groups and Go units | `tests/go-parity/run.sh make test-go-doctor-onion-parity test-go-status-parity test-go-doctor-parity test-go-parity`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard and fake daemons | `PITHEAD_IMPL=python make test-dashboard` and `PITHEAD_IMPL=python make test-fakes`: PASS, 3716 tests/97.42% and 54 tests | `tests/go-parity/run.sh make test-dashboard` and `tests/go-parity/run.sh make test-fakes`: PASS, same counts/coverage; backend remains Python |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: same result |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |

Additional checks pass: `go -C go test -tags=parity -race -count=1
./internal/doctor ./internal/status ./internal/onion` (57 tagged doctor comparison
groups plus units), `go -C go vet -tags=parity ./...` and the Linux build command
above. Cross-compilation provides no Linux runtime verdict. Adapter syntax, pinned
ShellCheck/shfmt, scoped Markdown and Go formatting checks pass. Current private
command/exit records use `.go-cache/logs/onion-*`. Independent static review found
no remaining defects. Existing tests, fixtures, goldens, lint rules and Make checks
remain unchanged; no Git write, download, Tor request, live probe or daemon contact
occurred.

## Config diagnostics and payout-address slice (2026-10-31)

`go/internal/address/` ports Monero block Base58/legacy Keccak and Tari
Base58/emoji/DammSum classification, network/feature checks and public-key
extraction. `go/internal/doctor/config.go` ports SSH release policy and ordered
payout-address findings, including placeholders, getter newline trimming and
DIY/appliance wording. Inputs are config-presence and getter outputs; JSON and
variant-file parsing and the production collector remain Bash. Verification
availability is an explicit input preserving shape-only/unchecked behavior when
Python cannot run. Non-ASCII Monero doctor input declines a native verdict because
Bash shape counting depends on locale; the reusable classifier uses byte counting.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Address classifiers and config diagnostics | `PITHEAD_IMPL=bash make test-go-doctor-config-parity`: PASS, 11 tagged comparison groups and Go units | `tests/go-parity/run.sh make test-go-doctor-config-parity test-go-doctor-parity test-go-parity`: PASS |
| CLI and doctor JSON | `PITHEAD_IMPL=bash make test-go-doctor-config-parity test-go-doctor-parity test-go-parity`: PASS, initial 10 address/config groups plus 13 JSON and 12 CLI groups | Combined Go command above: PASS, 11 + 13 + 12 groups |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard and fake daemons | `PITHEAD_IMPL=python make test-dashboard` and `PITHEAD_IMPL=python make test-fakes`: PASS, 3716 tests/97.42% and 54 tests | Same Go wrapper commands: PASS, same counts/coverage; backend remains Python |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: same result |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

Additional checks pass: `go -C go test -tags=parity -race -count=1
./internal/doctor ./internal/address`, `go -C go vet -tags=parity ./...` and the
Linux build command above. After the locale correction, `go -C go test -race
-count=1 ./internal/address`, `go -C go test -tags=parity -race -count=1 -run
TestConfigMoneroByteShape ./internal/doctor` and `go -C go test -count=1 ./...`
pass. The new byte-shape group also passes in both modes with `PITHEAD_IMPL=bash
go -C go test -tags=parity -count=1 -run TestConfigMoneroByteShape
./internal/doctor` and the same command through `tests/go-parity/run.sh`.
Cross-compilation provides no Linux runtime verdict. Adapter syntax, pinned
ShellCheck/shfmt, Go formatting and scoped Markdown checks pass.
Comparisons caught and corrected a missing word in the appliance Tari message;
review caught and corrected direct Monero shape counting under the C locale.
Independent static review now passes with no remaining defects. Private
command/exit records use `.go-cache/logs/config-*`. Existing tests, fixtures,
goldens, lint rules and Make checks remain unchanged; no Git write, download,
network request, live probe or daemon contact occurred.

## Network diagnostics slice (2026-10-31)

`host.PublicIP` and `PublicIPs` retain the legacy IPv4 exclusions, lexical
leading-zero behavior, permissive IPv6 first-hextet gate, interface order,
duplicates and unterminated-record handling. Native doctor packages port effective
stratum settings, exposure findings/setup warnings, container-state queries,
Tor-running findings, listener checks and the bounded Tor clearnet probe. They
retain getter gates, exact tool arguments, partial output on nonzero status,
short-circuit order and listener pipeline failures. Doctor exposure messages
withhold public IP and password values; setup warnings retain public IP values.
The production collector and dotenv parsing remain Bash.

Unsupported launches, NUL/overflow inputs, tool diagnostics and unusual narrowed
binds decline a native verdict. Narrowed exposure also falls back when grep is
missing, bind text looks like an option, or public output exceeds 512 bytes;
this preserves the original grep-option and printf/grep pipefail behavior.
Setup warning escapes also fall back.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Network probes | `PITHEAD_IMPL=bash make test-go-doctor-network-parity`: PASS, 16 tagged comparison groups and Go units | `tests/go-parity/run.sh make test-go-doctor-network-parity`: PASS |
| CLI and doctor JSON | `PITHEAD_IMPL=bash make test-go-doctor-network-parity test-go-doctor-parity test-go-parity`: PASS, 15 initial network groups plus 13 JSON and 12 CLI groups | Same targets through `tests/go-parity/run.sh`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests/97.42% | `tests/go-parity/run.sh make test-dashboard`: PASS on retry, same count/coverage; backend remains Python |
| Fake daemons | `PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: same result, including after the retry |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

`go -C go test -tags=parity -race -count=1 -run
'TestNetwork|TestStratumExposure|TestPublicIP' ./internal/doctor ./internal/host`,
`go -C go test -count=1 ./...`, `go -C go vet -tags=parity ./...` and the Linux
build command above pass. The final TLS-tool comparison also runs under race
checking with `go -C go test -tags=parity -race -count=1 -run
TestNetworkTLSNormalizationTools ./internal/doctor`: PASS. Linux compilation
provides no runtime verdict. Adapter syntax, pinned ShellCheck/shfmt pass;
Go formatting and scoped Markdown checks pass. Independent static review
passes with no remaining defects.

The first Go dashboard run had 3715 passes and one failure in
`TestBoundedRead.test_a_trickled_body_does_not_cost_quadratic_time` (5.66 seconds
against its unchanged four-second limit); the same full suite passed on retry.
Early new-harness compile, ShellCheck and diagnostic-stream assertions were
corrected before paired runs; one fixture process also reported a syntax error
during an adapter edit. Stable reruns pass. Existing tests, fixtures, goldens,
lint rules and Make checks remain unchanged. Private command/exit records use
`.go-cache/logs/network-*`. No Git write, download, real interface/listener probe,
external network request, live container or daemon contact occurred.

## LAN guard diagnostics slice (2026-10-31)

`go/internal/firewall/` implements read-only LAN rule verification for iptables
and nft, preserving return codes 0–5, terminal DROP checks, tagged jump coverage,
foreign ACCEPT/RETURN precedence and FORWARD reachability. The nft path retains
the legacy requirement that one forward-hooked drop rule mentions every port;
it retains the original acceptance of an earlier ACCEPT expression. It validates
all relevant expressions before returning success. Unsafe JSON precision,
fractional/extreme numbers, Unicode line separators, non-string rule chains,
unsupported shapes, noncanonical ports, NUL output, relative tool paths and
unusual executable formats decline a native verdict for future Bash fallback.

The doctor packages implement published-bind enumeration, readback reasons,
boot-unit applicability, restart-policy/exit-code hold reports and the combined
LAN report. They preserve container deduplication in hold checks, repeated
container/exit queries elsewhere, suppressed streams and the Docker-port/grep
pipeline's producer failure and SIGPIPE behavior. The production collector,
dotenv readers, firewall mutations, markers and recovery remain Bash.
The native path retains the source's permissive token/substring matching and
failed Docker-read classifications.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| LAN probes, doctor JSON and CLI | `PITHEAD_IMPL=bash make test-go-doctor-lan-parity test-go-doctor-parity test-go-parity`: PASS, 20 LAN groups plus 13 JSON and 12 CLI groups, and Go units | Same targets through `tests/go-parity/run.sh`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests/97.42% | `tests/go-parity/run.sh make test-dashboard`: PASS, same count/coverage; Python backend |
| Fake daemons | `PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: PASS, not applicable |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI/firewall suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

`go -C go test -tags=parity -race -count=1 -run TestLAN ./internal/doctor`,
`go -C go test -race -count=1 ./internal/firewall`,
`go -C go test -count=1 ./...`, `go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o
../.go-cache/pithead-linux-amd64 ./cmd/pithead` pass. The visible-systemctl-output
fallback witness also passes under race checking with
`go -C go test -tags=parity -race -count=1 -run TestLANHoldFallbacks
./internal/doctor`. Adapter syntax, pinned ShellCheck/shfmt, Go formatting and
scoped Markdown checks pass. Independent static and security review pass with
no remaining new defects.

An early `GOOS=linux GOARCH=amd64 go -C go test -run '^$'
./internal/firewall` failed when macOS could not execute the Linux test binary.
The corrected `GOOS=linux GOARCH=amd64 go -C go test -c -o
../.go-cache/firewall-linux-amd64.test ./internal/firewall` passes. These Linux
compilations provide no Linux runtime verdict.

Early comparisons corrected the new adapter's conditional calling context,
reason-output newline expectation, reached-tool fixture and formatting. A new
fractional-number witness initially expected the wrong Bash result; the recorded
oracle result is now asserted. Review found and corrected Unicode serialization
and array-valued rule-chain verdict differences through explicit fallback.
No existing test changed. Private command/exit
records use `.go-cache/logs/firewall-*`. No shared Git metadata write, external network request,
live firewall, container, systemd or daemon probe occurred.

## Docker Tor egress diagnostics slice (2026-10-31)

This slice starts at `e17928548b1b9ddadba3cfbcbf997a85b983344a`.

Native firewall helpers preserve the libxtables quoted-token format, partial
token output on malformed quotes, CIDR overlap/containment, source negation,
foreign-rule shadowing, sync-ACCEPT validation and canonical option ordering.
The Docker readback preserves return codes 0–5, rule order, exemption counts,
late/conditional/duplicate exemption rejection, tagged-rule membership and the
canonical FORWARD jump with preceding-rule checks. Exact state/config getter
outputs are supplied; their collection, marker interpretation, transitions and
all mutations remain Bash. Podman/nft readback declines a native verdict for
fallback. Doctor reports retain the toggle/Tor gates, backend/surface wording,
boot-unit warning and command arguments.

NUL, quoted newlines, unquoted non-ASCII text, unsafe arithmetic, octal prefixes in containment/overlap,
ambiguous trailing-dot arithmetic, unsupported executable formats and missing
text tools decline a native verdict. Decimal leading-zero validation and the
source's permissive tagged-rule membership behavior are preserved.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Tor egress probes | `PITHEAD_IMPL=bash make test-go-doctor-egress-parity`: PASS, 18 tagged groups and Go units, including after the locale fallback fix | `tests/go-parity/run.sh make test-go-doctor-egress-parity`: PASS |
| CLI and doctor JSON | `PITHEAD_IMPL=bash make test-go-doctor-egress-parity test-go-doctor-parity test-go-parity`: PASS, 18 egress, 13 JSON and 12 CLI groups, plus Go units | Same targets through `tests/go-parity/run.sh`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests/97.42% | `tests/go-parity/run.sh make test-dashboard`: PASS, same count/coverage; Python backend |
| Fake daemons | `PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: PASS, not applicable |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI/firewall suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

`go -C go test -tags=parity -race -count=1 -run TestEgress
./internal/firewall ./internal/doctor`, `go -C go test -count=1 ./...`,
`go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build
-o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` pass. Cross-compilation
provides no Linux runtime verdict. Adapter and scoped Markdown checks pass.
Independent static review passes with no remaining defects. A local Bash oracle
confirmed the U+2003 duplicate-source witness returns rc 1 in `C` and rc 0 in
`en_US.UTF-8`. The native parser now declines that locale-dependent input;
`go -C go test -race -count=1 -run TestEgressUnquotedUnicodeFallback
./internal/firewall` passes and also checks quoted Unicode preservation.

Initial new-test runs corrected the canonical empty-input case and a reordered
fixture whose leading jump did not satisfy the source's literal-space check.
A no-shebang fixture initially attempted to overwrite a tool symlink; the sandbox
blocked it, and the fixture now unlinks the symlink before creating its fake.
No external file changed. Private command/exit records use
`.go-cache/logs/egress-*`. Existing tests, fixtures, goldens, lint rules and Make
checks remain unchanged. No shared Git metadata write, dependency download,
external network request, live firewall, container, systemd, bench or daemon
probe occurred.

## Unavailable and known host constraints

- `make test-stack` deliberately refuses macOS; no Linux suite verdict is claimed.
- `make test` stops at Markdown lint on third-party content in the required local
  uv cache. Changed project Markdown is checked separately; the original gate
  remains unchanged and its failure is recorded above.
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

1. Port nft Tor egress readback and sync-state collection, Tor transition/history,
   remaining container checks and appliance-state checks.
2. Connect the native doctor collector and human output with Bash fallback for
   unsupported inputs and the pinned check-ID contract.
3. Port config parse, validate and render, including byte-identical `.env` and
   Caddyfile output.
4. Implement the dashboard Go command and container switch.
5. Run unchanged Linux/Docker suites and the reserved-bench experiment on the
   operator's infrastructure.
