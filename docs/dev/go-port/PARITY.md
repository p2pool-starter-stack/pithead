STATUS: IN PROGRESS

# Go port parity

Incremental port for issue #3811, starting from `a73ffced33800de9435779a9cabef53864455acb`
on branch `go-port/3811`. The owner authorized implementation on 2026-10-31;
bench measurements remain an operator task. No performance benefit is claimed.

## Scope and continuation criteria

Port the CLI, dashboard backend (including the first-boot wizard and control
channel), then practical appliance host and container entrypoint code. Preserve
Bash/Python, upstream daemons, browser assets, runtime filenames, database
migrations and wire formats. Existing tests, fixtures and checks remain unchanged.

The local continuation threshold is exact stdout, stderr and exit-code agreement
for each claimed CLI slice, with existing runnable suites passing in both modes.
The dashboard threshold adds identical HTTP/JSON contracts and successful reuse
of existing databases, including migrations and corrupt-database recovery.
Fallback passes do not establish a native Go implementation.

The issue's performance experiment is still outstanding. Measure CLI first-output
latency for help/status/doctor, apply and upgrade wall time, serial/parallel CLI
suite CPU and wall time, and module sizes, tested functions, mutable globals and
lint findings. Measure dashboard idle CPU, working/peak memory, cold/warm state
latency percentiles by range and client count, polling stalls, start/stop time,
image size and scan findings at 2/50/100 rigs, including within-arm noise.
Compare Bash/Go and Python/current, Python/algorithm fix, Go/identical algorithm
on the same reserved bench with restored seeded state and interleaved repetitions.
Correctness requires zero contract regressions. A performance-based continue/stop
threshold needs the operator's decision and bench noise measurements; none has
been approved or inferred here. This implementation follows the owner's later
instruction to begin the port without waiting for that experiment.

## Build and select

```bash
make go-build
PITHEAD_IMPL=go ./pithead --help
PITHEAD_IMPL=bash ./pithead --help
make test-go-parity
```

The Go module has no third-party dependencies and uses Go 1.23 language features;
this chunk was built with Go 1.27.1. Make's Go targets set `GOCACHE`, `GOMODCACHE`
and `GOPATH` under `.go-cache/`. Use `UV_CACHE_DIR="$PWD/.uv-cache"` for uv.
Both cache directories and `go/bin/` are ignored.

The generated CLI selects `go/bin/pithead` only for `PITHEAD_IMPL=go` and only when
executed. Sourcing continues to define reference Bash functions. The Go process
executes Bash for every unported command, retaining argv, standard streams,
exit codes and inherited file descriptors. It selects `PITHEAD_IMPL=bash` for
that process to prevent recursion. `PITHEAD_GO_BINARY` supports the copied CLI
fixtures; `PITHEAD_GO_REFERENCE` carries the original invocation path.
Unset, `bash` and `python` continue to use the reference CLI.
The dashboard/container selection is not implemented yet.

## Components and verbs

| Component / verb | Go status | Verified under Go selection |
|---|---|---|
| CLI dispatcher and fallback | Implemented | New black-box parity suite; Go unit tests |
| Subcommand `-h` / `--help` | Native (except logs passthrough) | New black-box parity suite; Go unit tests |
| `setup` | Bash fallback | Not independently proven in Go mode |
| `apply` | Bash fallback | Not independently proven in Go mode |
| `render` | Bash fallback | Not independently proven in Go mode |
| `up` | Bash fallback | Not independently proven in Go mode |
| `down` | Bash fallback | Not independently proven in Go mode |
| `restart` | Bash fallback | Not independently proven in Go mode |
| `tor-recover` | Bash fallback | Not independently proven in Go mode |
| `upgrade` | Bash fallback | Not independently proven in Go mode |
| `logs` | Bash fallback | Fallback refusal checked by new parity suite |
| `status` | Native single-command path; flags, chains and missing Docker use Bash fallback | Go status units and paired synthetic status suite |
| `test-alert` | Bash fallback | Not independently proven in Go mode |
| `doctor` | Go JSON report formatting with Bash probes; human output, terminal JSON and unsupported cases use Bash fallback | Go report units, paired synthetic JSON suite, unchanged sourced JSON contract |
| Doctor memory and clock probes | Native packages; CLI collector still uses Bash | Go units and tagged Bash comparison suite |
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
| `version` | Native, including `-V` / `--version` | New black-box parity suite; Go unit tests |
| `help` | Native, including `-h` / `--help` | New black-box parity suite; Go unit tests |
| Config parse/validate/render, `.env`, Caddyfile | Bash fallback | Not yet ported |
| Dashboard routes, state, polling and Tor | Python reference | Not yet ported |
| SQLite schema, migrations and recovery | Python reference | Not yet ported |
| Wizard launch and control channel | Bash/Python reference | Not yet ported |
| Appliance host scripts and container entrypoints | Reference scripts | Not yet ported |

## Harness adapters

Only new files were added under `tests/go-parity/`:

- `env.sh`: a `BASH_ENV` hook restores Go selection for child Bash invocations.
  The unchanged shell harness clears all `PITHEAD_*` variables, and its temporary
  installs copy only the generated CLI. This hook supplies the selected binary
  path to those children and preserves explicit Bash fallback.
- `run.sh`: runs an unchanged command with that hook and local caches;
  with no arguments it invokes `make test-stack`.
- `test_status.py` and `status_fixture.py`: compare native status with the Bash
  reference against synthetic engine, curl and OpenSSL executables. This reaches
  the native CLI path on macOS without bypassing the unchanged Linux suite guard.
  The fixture never contacts a Docker daemon or dashboard.
- `test_doctor.py` and `doctor_fixture.sh`: use a temporary copy of the generated
  CLI with a sourced probe override inserted immediately before `main`. The real
  prelude, dispatcher and Bash JSON formatter remain in that copy. This reaches
  Go report formatting without host, network or running-container checks, and
  compares bytes, stderr and exit codes. It also proves Go formats without jq.
- `doctor_memory_reference.sh`: sources the unchanged generated CLI and invokes
  individual memory and clock probes against synthetic inputs. For inline
  free-RAM and clock verdicts it extracts the existing source block, checks its
  boundaries and substitutes only the fixture meminfo path. The tagged Go
  comparison suite uses this adapter because the original shell tests source
  Bash functions. It does not bypass their Linux platform guard.
- `test_cli.py`: compares bytes and exit codes from the same generated entrypoint
  in disposable synthetic installs. It also proves native help/version avoid
  Bash execution, and checks fallback argument and exit-code preservation.

```bash
PITHEAD_IMPL=bash make test-stack
tests/go-parity/run.sh make test-stack
```

Sourced Bash unit functions still exercise the reference implementation. The
adapter currently selects Go for black-box child CLI calls, not sourced functions.
A future native feature needs its own adapter where existing tests only source Bash.

## Results (2026-10-31)

All commands below used worktree-local Go and uv caches, a temporary directory
under `.go-cache/`, `UV_OFFLINE=1`, `UV_PYTHON_DOWNLOADS=never`, and
`npm_config_offline=true`. No dependencies were downloaded. Raw logs and command
exit/status records are retained locally under `.go-cache/logs/`.
Results apply to this initial scaffolding chunk, not whole-application parity.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Native Go tests + paired CLI parity | Same synthetic installs, reference Bash arm | `make test-go-parity`: PASS; Go unit tests and 12 paired black-box tests |
| Frontend | `PITHEAD_IMPL=bash make test-frontend`: PASS, 891/891 | `tests/go-parity/run.sh make test-frontend`: PASS, 891/891 |
| Portable tools | `PITHEAD_IMPL=bash make test-tools`: PASS | `tests/go-parity/run.sh make test-tools`: PASS |
| Netwatch/tool installer selftests | `PITHEAD_IMPL=bash make test-netwatch`: PASS | `tests/go-parity/run.sh make test-netwatch`: PASS |
| File budget + CLI build guards, starting-commit base | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb PITHEAD_IMPL=bash make lint-file-budget lint-pithead-build`: PASS | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb tests/go-parity/run.sh make lint-file-budget lint-pithead-build`: PASS |
| File budget, default base | `PITHEAD_IMPL=bash make lint-file-budget lint-pithead-build`: FAIL against default develop base | `tests/go-parity/run.sh make lint-file-budget lint-pithead-build`: same FAIL; CLI-build guard not reached in this attempt |
| Documentation voice, path references, operator strings | `PITHEAD_IMPL=bash make lint-docs-voice lint-path-references lint-operator-strings`: PASS | `tests/go-parity/run.sh make lint-docs-voice lint-path-references lint-operator-strings`: PASS |
| Documentation voice, path references, operator strings, topology | `PITHEAD_IMPL=bash make lint-docs-voice lint-path-references lint-operator-strings lint-topology`: first three PASS; topology selftest FAIL | `tests/go-parity/run.sh make lint-docs-voice lint-path-references lint-operator-strings lint-topology`: same result |
| Full local gate | `PITHEAD_IMPL=bash make test`: shell lint PASS, then blocked at offline Python dependency resolution (exit 2) | `tests/go-parity/run.sh make test`: same result (exit 2) |
| Integration harness selftests | `PITHEAD_IMPL=bash make test-integration-selftest`: FAIL at auth fail-closed fixture, GNU utility assumptions (exit 2) | `tests/go-parity/run.sh make test-integration-selftest`: same fixture result, 15 passed / 11 failed (exit 2) |
| Shell CLI suite | `PITHEAD_IMPL=bash make test-stack`: platform refusal (exit 2) | `tests/go-parity/run.sh make test-stack`: same refusal (exit 2) |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: dependency resolution blocked (exit 2) | `tests/go-parity/run.sh make test-dashboard`: same blocker (exit 2); backend remains Python |
| Fake-daemon contracts | `PITHEAD_IMPL=python make test-fakes`: dependency resolution blocked (exit 2) | `tests/go-parity/run.sh make test-fakes`: same blocker (exit 2); backend remains Python |

The parity tests cover aliases, subcommand help precedence, chain precedence,
release/source/missing versions, literal argv, refusal fallback, inherited fd 9,
fallback SIGTERM, and closed stdout (help's exit 141 and diagnostic; version's
SIGPIPE). They assert native help/version do not execute Bash. Test subprocesses
discard inherited operator configuration variables and use synthetic installs.

New adapter shell files also pass `bash -n`, ShellCheck 0.11.0 and shfmt 3.13.1.
Go formatting and `git diff --check` pass.

## Native status slice (2026-10-31)

`go/internal/status/` now owns the service census and verdict ordering, profile
selection, two-snapshot restart observation, migration marker ownership, chain
health lines, dashboard sync holds/progress, clearnet attestation and banner,
onion text, and stratum password/TLS announcements. It retains the existing
external Docker/Podman, curl, jq and OpenSSL commands. The original Bash status
and sourced functions remain intact.

The Go command executes native status for a single bare `status`. Subcommand
help remains native; unsupported arguments, chains and a missing Docker binary
use the Bash reference so its existing diagnostics remain available.
Clearnet verification reads marker metadata without following symlinks and
compares exact inode/timestamp values, including Python-compatible JSON number
semantics. Linux and macOS use their native stat timestamp fields.

```bash
make test-go-status-parity
```

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Native status parity | Reference Bash arm in the same synthetic installs | `make test-go-status-parity`: PASS, 9 paired test groups including terminal colors |
| Scaffolding/help/version parity | Reference Bash arm in the same synthetic installs | `make test-go-parity`: PASS, 12 paired tests |
| Restart observer selftest | `PITHEAD_IMPL=bash bash tests/os/selftest-container-restarts.sh`: PASS | `tests/go-parity/run.sh bash tests/os/selftest-container-restarts.sh`: PASS; this suite sources Bash functions |
| Frontend | `PITHEAD_IMPL=bash make test-frontend`: PASS, 891/891 | `tests/go-parity/run.sh make test-frontend`: PASS, 891/891 |
| Portable tools | `PITHEAD_IMPL=bash make test-tools`: PASS | `tests/go-parity/run.sh make test-tools`: PASS |
| Netwatch/tool installer selftests | `PITHEAD_IMPL=bash make test-netwatch`: PASS | `tests/go-parity/run.sh make test-netwatch`: PASS |
| File budget and CLI build guards | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb PITHEAD_IMPL=bash make lint-file-budget lint-pithead-build`: PASS | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb tests/go-parity/run.sh make lint-file-budget lint-pithead-build`: PASS after cache cleanup |
| Markdownlint | `npm_config_cache="$PWD/.go-cache/npm" PITHEAD_IMPL=bash make lint-md`: PASS | `npm_config_cache="$PWD/.go-cache/npm" tests/go-parity/run.sh make lint-md`: PASS |
| Documentation voice and operator strings | `PITHEAD_IMPL=bash make lint-docs-voice lint-operator-strings`: PASS | `tests/go-parity/run.sh make lint-docs-voice lint-operator-strings`: PASS |
| Full local gate | `PITHEAD_IMPL=bash make test`: shell lint PASS, then blocked by uncached grpcio (exit 2) | `tests/go-parity/run.sh make test`: shell lint PASS, then blocked by uncached grpcio (exit 2) |
| Shell CLI suite | `PITHEAD_IMPL=bash make test-stack`: macOS refusal (exit 2) | `tests/go-parity/run.sh make test-stack`: same refusal (exit 2) |

Additional checks: `make test-go`, `go -C go test -race ./internal/status`, and
`go -C go vet ./...` pass with local Go caches. The CLI cross-compiles for
Linux/amd64; this is a build check, not Linux runtime evidence.

Pinned Ruff 0.17.0 was installed as a standalone tool under `.uv-cache/` with
`UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, and `UV_CACHE_DIR` confined there. Pinned
markdownlint-cli2 0.18.1 was downloaded with npm's cache under `.go-cache/npm`.
These tool packages were the only downloads in this slice. Ruff's full check and
format check pass for the new adapters. Locked application Python dependencies remain unavailable offline.
Standalone pinned Ruff also passes `check .` and `format --check .` for the whole
repository in both selection modes (with `RUFF_CACHE_DIR=.uv-cache/ruff`):

```bash
PITHEAD_IMPL=bash .uv-cache/bin/ruff check .
PITHEAD_IMPL=go .uv-cache/bin/ruff check .
PITHEAD_IMPL=bash .uv-cache/bin/ruff format --check .
PITHEAD_IMPL=go .uv-cache/bin/ruff format --check .
```

The new adapters have per-call subprocess pragmas for their fixed synthetic
executables; no existing lint rule or check changed.

Initial Go file-budget attempts caught temporary cross-compile/review caches created
under the module directory. Those caches were removed, the Linux binary retained
under the ignored root `.go-cache/`, and the gate was rerun with root caches.
Logs and exit records for this slice are `.go-cache/logs/status-*.log` and their
adjacent JSON records. An initial terminal-test adapter read after PTY closure
and lost stdout on macOS; it now drains output concurrently and retains the same
byte/color assertions. No benchmark conclusion follows from test durations.

## Doctor JSON report slice (2026-10-31)

`go/internal/doctor/` builds the ordered, indented JSON report for a single
`doctor --json` invocation with captured stdout. Diagnostic probes still execute
the retained Bash `doctor` once; their human output goes to stderr. Go preserves
check ordering, nullable missing TSV fields, summary counts, version and failure
status. Its string encoding matches jq for HTML, Unicode separators, malformed
UTF-8, control bytes and DEL. Closed stdout preserves the probe's exit status.
The retained Bash probe function writes an optional private completion marker
after its summary. Go uses it to distinguish a normal diagnostic failure from
an abrupt shell exit, which must not produce JSON. Probe signals are forwarded
and retain signal termination. Both temporary files are removed after collection.

Human `doctor`, terminal JSON output, missing jq and unsupported arguments keep
using Bash. This slice ports report construction, not diagnostic checks or host
discovery. The Bash libraries and their pinned check-id catalog are unchanged.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Doctor report parity | Reference Bash formatter in the same synthetic installs | `make test-go-doctor-parity`: PASS, 13 paired test groups and Go unit tests; adapter-run target also PASS |
| Help/version/dispatch and status regression | Reference Bash arms in the same synthetic installs | `make test-go-parity test-go-status-parity`: PASS, 12 + 9 paired groups |
| Unchanged doctor JSON contract | `PITHEAD_IMPL=bash python3 tests/stack/doctor/test-json-contract.py`: PASS, 2 tests | `tests/go-parity/run.sh python3 tests/stack/doctor/test-json-contract.py`: PASS, 2 tests; sources Bash functions |
| Pinned doctor source catalog | `PITHEAD_IMPL=bash python3 tests/stack/doctor/check-ids.py .`: PASS | `tests/go-parity/run.sh python3 tests/stack/doctor/check-ids.py .`: PASS; source catalog only, no generated reports supplied |
| File budget, CLI build guards, documentation voice and operator strings | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb PITHEAD_IMPL=bash make lint-file-budget lint-pithead-build lint-docs-voice lint-operator-strings`: PASS | Same base with `tests/go-parity/run.sh make lint-file-budget lint-pithead-build lint-docs-voice lint-operator-strings`: PASS |
| Pinned Ruff | `PITHEAD_IMPL=bash .uv-cache/bin/ruff check .` and `format --check .`: PASS | Same commands with `PITHEAD_IMPL=go`: PASS |
| Markdownlint | `npm_config_cache=.go-cache/npm PITHEAD_IMPL=bash make lint-md`: PASS | Same cache with `tests/go-parity/run.sh make lint-md`: PASS |
| Full local gate | `PITHEAD_IMPL=bash make test`: shell lint PASS, blocked by uncached grpcio (exit 2) | `tests/go-parity/run.sh make test`: same result (exit 2) |

Additional checks pass with local caches: `go -C go test -race ./internal/doctor`,
`go -C go vet ./...`, and Linux/amd64 cross-compilation. This is build evidence,
not a Linux runtime verdict. New subprocesses use only synthetic probe fixtures.
Logs and exit records for this slice are `.go-cache/logs/doctor-*.log` and their
adjacent JSON records. No dependencies were downloaded in this slice.

The initial adapter replaced the dispatcher; it now retains the generated entrypoint
and substitutes only probe collection. That stronger test exposed partial JSON
after an abrupt probe exit; the completion marker fixes it. An initial standalone
shell-lint attempt included source slices without the generated script's context;
the corrected check uses `pithead` and the new adapters, matching the existing
Make scope. The sourced fixture has the required Bash tool pragma and passes shfmt.
No existing check or assertion changed. Independent review found no remaining
defects in this slice.

## Doctor memory and clock probe slice (2026-10-31)

`go/internal/doctor/memory.go` implements the reservation decision, HugePages
shortfall verdict, degraded-marker message and available-RAM verdict.
`go/internal/doctor/clock.go` implements the clock-sync probe and its surface-aware
verdict. Findings retain the Bash check IDs, severities and messages.

These are package-level ports. The CLI collector still executes Bash; local-miner
gating, the remaining host checks and native orchestration are outstanding.
Unsupported arithmetic, NUL values and degraded-marker read errors return
`ErrUnsupportedProbeInput` without a finding. Bash handling must remain available
for those inputs when the native collector is connected.

`make test-go-doctor-memory-parity` runs Go units and the additional `parity`-tagged
comparison suite. Its oracle sources the unchanged generated CLI. The tag keeps
plain Go units independent of the generated artifact; no existing test was tagged,
skipped or changed. Go targets now create and use `.go-cache/tmp` as `TMPDIR`.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Memory and clock findings | `PITHEAD_IMPL=bash make test-go-doctor-memory-parity`: PASS, 11 comparison groups and Go units | `tests/go-parity/run.sh make test-go-doctor-memory-parity`: PASS; both commands compare native findings with Bash in the same synthetic fixtures |
| CLI/status/JSON regressions | Reference Bash arms in the same synthetic installs | `make test-go-doctor-parity test-go-parity test-go-status-parity`: PASS, 13 + 12 + 9 groups |
| Pinned Ruff | `PITHEAD_IMPL=bash .uv-cache/bin/ruff check .` and `format --check .`: PASS | Same commands with `PITHEAD_IMPL=go`: PASS |
| File budget, CLI build guards, documentation voice and operator strings | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb PITHEAD_IMPL=bash make lint-file-budget lint-pithead-build lint-docs-voice lint-operator-strings`: PASS | Same base with `tests/go-parity/run.sh make lint-file-budget lint-pithead-build lint-docs-voice lint-operator-strings`: PASS |
| Markdownlint | `npm_config_cache=.go-cache/npm PITHEAD_IMPL=bash make lint-md`: PASS | Same cache with `tests/go-parity/run.sh make lint-md`: PASS |
| Unchanged doctor JSON contract | `PITHEAD_IMPL=bash python3 tests/stack/doctor/test-json-contract.py`: PASS, 2 tests | `tests/go-parity/run.sh python3 tests/stack/doctor/test-json-contract.py`: PASS; sources Bash |
| Pinned source catalog | `PITHEAD_IMPL=bash python3 tests/stack/doctor/check-ids.py .`: PASS | `tests/go-parity/run.sh python3 tests/stack/doctor/check-ids.py .`: PASS; catalog only |
| Full local gate | `PITHEAD_IMPL=bash make test`: shell lint PASS, uncached grpcio blocks Python lint (exit 2) | `tests/go-parity/run.sh make test`: same result (exit 2) |
| Shell CLI suite | `PITHEAD_IMPL=bash make test-stack`: macOS refusal (exit 2) | `tests/go-parity/run.sh make test-stack`: same refusal (exit 2) |

Additional checks pass: `go -C go test -tags=parity -race -count=1 ./internal/doctor`,
`go -C go vet -tags=parity ./...`, and Linux/amd64 cross-compilation, with local
caches. The new adapter passes `bash -n`, ShellCheck 0.11.0 and shfmt 3.13.1.
No Linux runtime result follows from cross-compilation. Logs and exit records
are `.go-cache/logs/memory-*.log` and adjacent JSON files. No downloads occurred.

Independent review caught signed leading-zero arithmetic: Bash interprets the
digits after `+` or `-` as octal too. The implementation and exact reference
comparisons now cover that case. Review of the corrected slice found no remaining
defects. Unsupported input cases verify the error boundary rather than claiming
a native verdict; production still uses Bash for every probe.

## Unavailable and skipped checks

- `make test-stack` deliberately refuses macOS; the existing Linux-only suite was
  neither bypassed nor modified. No Linux test verdict is claimed.
- `make test`, `make test-dashboard`, and `make test-fakes` cannot resolve the
  locked Python environment offline (`grpcio` 1.84.0 and/or Pygments 2.20.0 absent
  from the local cache). The network policy allows only Go/tool downloads;
  dependency fetching was disabled. No dashboard or fake-daemon suite was collected or passed.
- Patch coverage was not run because dashboard coverage output could not be made.
- The default file-budget gate compares this version branch against `develop`,
  finding two existing budget differences: the firstboot wizard ceiling and a
  provision-browser-submit row. The same unchanged gate passes when its documented
  base override points to this port's starting commit. No budget entries changed.
- Integration selftests stop at `selftest-auth-fail-closed.sh` in both modes:
  BSD `stat` rejects `-c` and BSD `chown` rejects the GNU option form, leaving
  that fixture at 15 passed / 11 failed. Later selftests were not reached.
- The topology scanner's selftests fail on this BSD userland in both modes,
  including unrelated IPv6, username and systemd-path controls. Its rules and
  selftests were not changed.
- Markdownlint and standalone Ruff were unavailable during scaffolding checks.
  The status slice installed pinned tools locally as recorded above; the full
  Make gate still cannot resolve the locked application environment offline.
- Compose/Caddy parsing, container/image tests, the mini-stack, KVM and live matrix
  require Docker, a reserved bench, or hardware. They were not run. No Docker daemon,
  bench or LAN host was contacted.
- Bench performance measurements, image sizes/scans and acceptance ADRs remain
  unmeasured; local test durations are not benchmark evidence.

Navigation used a local CLI-only graph (96 files, 825 nodes, 1099 edges), with
zero LLM input/output tokens. Its diagnostic reports 14 collapsed relation pairs
and an installed-tool/skill version mismatch; it is a partial navigation aid,
not parity evidence.

## Handoff

The scaffolding, native status, doctor JSON reporting and memory/clock packages
are ready for commit as `go: add CLI scaffold and doctor probe parity`.
The session could not stage files: Git's shared worktree metadata is outside the
writable sandbox, and creating `index.lock` failed with `Operation not permitted`.
No commit was created. The branch head is still the starting SHA above; all changes
remain in this worktree. No existing test, fixture, lint rule or check was changed.

## Next

1. Commit this chunk when Git metadata is writable.
2. Port the remaining doctor probes and connect native collection and human output;
   retain Bash fallback for unsupported inputs and the pinned check-id contract.
3. Add adapters for sourced feature functions, then port config parse/validate/render.
4. Implement the dashboard Go command and container switch during the backend phase.
5. Have the operator run unchanged Linux/Docker suites and the reserved-bench experiment.
