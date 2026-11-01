# Configuration port results

Historical paired commands, results and limits from the Go port.
Each section preserves that slice's status at the time; see the
[parity ledger](PARITY.md) for current implementation status.

## Config document slice (2026-10-31)

`go/internal/config/document.go` preserves ordered JSON, duplicate/placeholder
reason bytes, ASCII-safe paths, request scope and syntax-before-duplicate ordering.
Five tagged groups compare 134 scenarios. Invalid UTF-8, surrogate escapes,
nonstandard numbers, integers over 4096 digits and nesting beyond 128 retain Python.
Typed/default validation and `.env`/Caddyfile rendering remain Bash.

Go-selected fallback carries an internal binary marker for the native gate;
sourced tests use `PITHEAD_GO_BINARY`. Helper status 125 silently selects Python.
Wiring tests prove native selection through CLI fallback; compatibility tests
compare the selected fallback's exact bytes and status.
Private logs/exit records use `.go-cache/logs/config-document-*`.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with local caches.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-document-parity` | PASS, 5 tagged groups / 134 scenarios, 7 unchanged parser tests, 5 wiring tests | PASS, same counts; parser tests reach Go |
| `make test-go-parity` | PASS, 12 paired CLI groups plus Go units | Same result |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` with absent Docker socket and local npm cache | FAIL, 22 third-party cache Markdown findings, exit 2 | Same result; shell/Python/JS/YAML lint pass |
| `make test-stack` | macOS refusal, exit 2 | Same refusal |

After `make go-build`, native checks pass: `go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead`
(compilation only). Adapter syntax, pinned ShellCheck/shfmt, Ruff, Go formatting
and `git diff --check` pass. Reviews are clean; scoped Markdown passes in both modes:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-node-probes.md
```

[Back to the parity ledger](PARITY.md)

## Config defaults and getter slice (2026-10-31)

`go/internal/config/defaults.go` consumes the shell's runtime table on stdin;
`jq_json.go` preserves ordered JSON and raw-string bytes. Go implements
`config_defaults`, `default_of`, `new_install_defaults` and `config_get`, including
appliance/legacy overlays, materialization, path splitting and null-only fallback.
No defaults asset is duplicated. Producer status is framed separately so failed
table generation cannot emit native output before Bash retries.

Five tagged groups compare 744 scenarios. Six wiring tests prove jq is bypassed,
runtime overrides are honored and failed producers retain exact output/status.
They also run the unchanged v2.0.0 render fixture on DIY/appliance in both modes:
full `.env` bytes and miner/host records match the unchanged goldens. The renderer
itself remains Bash. Typed validation and Caddyfile rendering are not yet ported.
Noncanonical numbers, duplicate/malformed JSON, unsupported paths and TTY output
retain jq. Compatibility cases compare exact fallback stdout/stderr/status.
Private records use `.go-cache/logs/config-defaults-*`.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with local caches.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-defaults-parity` | PASS, 5 groups / 744 scenarios and Go units | Same result |
| `python3 tests/go-parity/test_config_defaults.py` | PASS, 6 wiring/render-fixture tests | Same result |
| `make test-go-config-document-parity test-go-parity` | PASS, unchanged parser and CLI suites plus Go units | Same result |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` with absent Docker socket and local npm cache | FAIL, 22 third-party cache Markdown findings, exit 2 | Same result; shell/Python/JS/YAML lint pass |
| `make test-stack`; `bash tests/stack/standalone/test_config_defaults.sh` | macOS refusal, exit 2 / 1 | Same refusal; no bypass |

After `make go-build`, native checks pass: `go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead`
(compilation only). An initial bare `go test ./...` used host temp paths and hit
unchanged Darwin `/var` symlink assertions; `make test-go` with the required local
`TMPDIR` passes. Adapter syntax, pinned ShellCheck/shfmt, Ruff, Go formatting and
`git diff --check` pass. Source/security reviews are clean. Scoped Markdown passes:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-config.md \
  docs/dev/go-port/results-baseline.md
```

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

## Caddyfile serialization slice (2026-10-31)

Native Go serialization covers the global/redirect prefix, the main dashboard
vhost and both onion vhosts. The Bash renderer supplies prepared address lists,
bind addresses, auth/TLS text and the boot capability through NUL-delimited stdin.
A terminal marker preserves trailing newlines across shell capture. Bash retains
address discovery/filtering, auth decoding, certificate minting, log/error order
and file writes. Unsupported helper requests keep the original render blocks.

The `.env` renderer and remaining typed validation still use Bash. No runtime
performance claim is made for this intermediate serializer boundary.
Private records use `.go-cache/logs/config-caddy-*`.

Five tests compare 32 complete render cases, including the scheme/port/auth
matrix, IPv6, appliance bind filtering and certificate reuse/mint failures,
onion auth refusal, partial files and write failures. A shim records only
section names and actual Go status, requiring success for all four sections.
The adapter isolates its fixture binary from inherited `BASH_ENV`; the initial
Go-selected run exposed that collision before the corrected paired runs passed.
Existing tests, fixtures, budgets and checks remain unchanged.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with local caches and an absent
Docker socket. Private command/exit records are under the prefix above.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-caddy-parity` | PASS, 5 tests / 32 render cases and Go units | Same result; all four native sections proven |
| `make test-go-config-defaults-parity test-go-config-document-parity test-go-config-validation-parity test-go-parity` | PASS, config/CLI comparisons, unchanged parser and render goldens, Go units | Same result |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS after splitting the new helper | Same result |
| `make test` | FAIL, existing `config_defaults_reference.sh` case indentation, pinned shfmt, exit 2 | Same failure; ShellCheck passes |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML PASS; Markdown FAIL, 22 third-party cache findings, exit 2 | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |

The new protocol hook lives in `lib/pithead/35a-caddy-go-render.sh`, ordered after
the original renderer; this keeps its file at 399 lines without a budget change.
Initial budget and Python-format findings on this slice were corrected before
the final checks. The previous adapter's formatting remains unchanged.
The Docker-backed `tests/stack/standalone/test_caddyfile.sh` parser was not run;
no daemon/parser acceptance or bench performance is claimed.

Native checks pass with canonical worktree cache/temp paths:
`go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead`
(compilation only). A preliminary `go test ./...` used a `go/../.go-cache/tmp`
`TMPDIR` and hit existing Darwin path assertions; canonical paths pass.
Go formatting, pinned Ruff, adapter syntax, ShellCheck/shfmt and
`git diff --check` pass. Source/security reviews found no remaining issues.
Scoped Markdown is checked with the original configuration:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-config.md
```

## Bulk environment serialization slice (2026-11-01)

Go serializes all 133 ordered `.env` assignments in one batch from prepared Bash
values. `lib/pithead/33a-go-env-render.sh` sends key/value pairs over stdin;
producer status is framed separately so an incomplete/failed producer emits no
native output. The terminal marker preserves trailing newlines across capture.
The original Bash value derivation, Tari secret-file transaction, `umask 077`,
cat writes and mandatory `chmod 600` remain in place. The two read-only render
getters are captured once before selection with their original nested-command
failure and diagnostic behavior, so a compatibility retry cannot repeat them.

Go matches the Bash quoting/escape contract for supported values. Locale-specific
Unicode whitespace/control/format values, invalid UTF-8, unusual locales,
unsupported targets and unavailable helpers retain the original renderer.
The remaining typed validation and config value derivation are still Bash.

The existing `test_config_defaults.py` runs the unchanged v2.0.0 render fixture
and compares its complete `.env` bytes with unchanged DIY/appliance goldens.
It passes in both modes with this serializer selected. This is local oracle
evidence; the complete original CLI suite and Compose dotenv parser require
Linux/Docker and remain unproven here. New comparisons supplement that evidence.
Private command/exit records use `.go-cache/logs/config-env-*`.

Seven new tests compare ordered bulk/value escaping, malformed/failed producer
frames, eight complete render cases, four target failures, compatibility fallback
and cached getter diagnostics/ERR traps. They require one successful native batch
for supported renders and compare `.env`/Tari secret-file bytes and 0600 modes.
No existing test, fixture, golden, budget or check changed.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with worktree caches and an absent
Docker socket.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-defaults-parity` | PASS, including unchanged render fixture/goldens | Same result, native batch separately verified |
| `make test-go-config-document-parity test-go-config-validation-parity test-go-caddy-parity test-go-parity` | PASS, including unchanged raw parser suite and prior comparisons | Same result |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `make test-go-env-parity` | PASS, 7 supplementary tests and Go units | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` | FAIL, existing `config_defaults_reference.sh` case indentation, pinned shfmt, exit 2 | Same failure; ShellCheck passes |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML PASS; Markdown FAIL, 22 third-party cache findings, exit 2 | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |

Native checks pass with canonical worktree cache/temp paths:
`go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead`
(compilation only). Generated-CLI and adapter ShellCheck, shfmt, Go formatting,
locked Ruff and `git diff --check` pass. Initial formatting findings in the new
tests were corrected using the repository gate. Source/security reviews are clean.
Scoped Markdown uses the original configuration:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-config.md
```
