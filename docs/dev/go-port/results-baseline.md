# Baseline and early port results

Historical suite evidence retained from the initial port rounds.

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

[Back to the parity ledger](PARITY.md)
