# Go render port results

Historical results for issue #3811; current scope, status and next work are in
[PARITY.md](PARITY.md). Commands below are historical invocations before archival. Existing suites and
fixtures remain unchanged.

## Memory render settings slice (2026-11-01)

Go reads the Tari/Monero memory settings with the original jq fallback semantics.
Nonlocal Tari modes retain the inert `0m` placeholder and skip the Tari memory
lookup. The native auto calculation subtracts HugePages, reserves one quarter
with a 2 GiB minimum, then floors the Tari ceiling at 2 GiB. Unknown RAM uses
16 GiB, matching the reference. Explicit configured limits keep their bytes.

`lib/pithead/33d-go-env-memory.sh` supplies config and memory facts over stdin.
The settings producer reports its status; both operations require complete NUL
fields, successful helper exit and EOF before committing values. Unsupported
JSON/numeric formats and malformed helpers retain the original Bash path.
Bash keeps hardware discovery, fact normalization, secret-file transactions and
all writes. This slice adds no host or network probe and changes no existing test.

The unchanged render fixture/goldens and raw-parser suite pass in both modes.
Seven supplementary Python tests compare full output, `.env`/secret bytes and
0600 modes, hardware-read order, explicit and nonlocal modes, memory boundaries,
unsupported settings and poisoned helper plans. Native success is verified.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with worktree caches and an absent
Docker socket. Private command/status records use `.go-cache/logs/config-memory-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-env-memory-parity test-go-config-defaults-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-config-document-parity test-go-config-validation-parity test-go-caddy-parity test-go-parity` | PASS, including unchanged render fixture/goldens, raw parser suite and 7 new memory tests | Same result, native memory settings/formula verified |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` | FAIL, existing `config_defaults_reference.sh` case indentation, pinned shfmt, exit 2 | Same failure; ShellCheck passes |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML PASS; Markdown FAIL, third-party cache findings, exit 2 | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |

Native checks pass with canonical worktree cache/temp paths:
`go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead`
(compilation only). Generated-CLI/new-adapter ShellCheck and shfmt, Go formatting,
locked Ruff and `git diff --check` pass. Source/security reviews are clean.
Scoped Markdown uses the original rules:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-config.md
```

## Caddy site preparation slice (2026-11-01)

Go now formats the HTTP/HTTPS site lists and normalizes scheme-default ports
inside the existing Caddy fragment calls. Bash supplies its expanded host tokens,
preserving IFS, globbing, order and duplicates. The tagged `sites-v1` frame checks
host count, producer status and EOF before rendering; the legacy frame remains
supported. This adds no helper processes. Unsupported helpers retain Bash fallback.

Bash keeps bind discovery, auth decoding, certificate preparation, reference port
preparation, logs and file writes. The original Caddy source slice is unchanged,
so standalone source consumers retain their existing dependencies and behavior.
The existing supplementary Caddy comparisons pass unchanged, including partial-file
failures. Bash command-substitution newline trimming is retained at the Go
protocol boundary. Three new supplementary tests cover whole-file bytes, call
order, host/port/IFS cases, native execution and malformed frames. The original
Linux CLI and Docker Caddy parsing suites remain unproven locally.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with worktree caches and an absent
Docker socket. Private command/status records use `.go-cache/logs/config-caddy-sites-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-caddy-sites-parity test-go-caddy-parity test-go-config-defaults-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-config-document-parity test-go-config-validation-parity test-go-parity` | PASS, including unchanged render fixture/goldens and raw parser suite | Same result |
| `make test-go-caddy-sites-parity test-go-caddy-parity` (final newline fix) | PASS, 3 new and 5 unchanged supplementary tests; Go units | Same result; native sections verified |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` | FAIL, existing `config_defaults_reference.sh` case indentation, pinned shfmt, exit 2 | Same failure; ShellCheck passes |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML PASS; Markdown FAIL, 22 third-party cache findings, exit 2 | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |

Native checks pass: `make go-build test-go`,
`go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead`
(compilation only). Generated CLI/new-adapter ShellCheck and shfmt, Go formatting,
locked Ruff, scoped Markdown and `git diff --check` pass. Source/security reviews
are clean. Scoped Markdown uses the original rules:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-render.md
```

## Stratum endpoint slice (2026-11-01)

Go parses the stratum bind and port for supported scalar settings with the same
jq defaults, IPv4 shape, decimal bounds and leading-zero acceptance as Bash.
Bind validation precedes the port read. A bad bind updates only `STRATUM_BIND`;
a bad port updates both globals before the original error function runs.

The hook in `lib/pithead/27b-stratum-endpoint.sh` accepts complete NUL frames,
helper success, a recognized stage and EOF before changing globals. Unsupported
JSON, scalar formats or helpers retain the original Bash path. No existing test
or fixture changed. Six supplementary tests compare exact bytes/status, partial
state, repeated parses, native execution without jq and malformed-helper fallback.
The unchanged standalone stratum preflight suite passes in both modes. Render
fixture/goldens exercise the full parser; the full Linux stack suite remains unavailable.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with worktree caches and an absent
Docker socket. Private command/status records use `.go-cache/logs/config-stratum-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-stratum-parity test-go-config-validation-parity test-go-config-defaults-parity test-go-config-document-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-caddy-parity test-go-caddy-sites-parity test-go-parity` | PASS, including unchanged raw parser and render fixture/goldens | Same result, 6 supplementary stratum tests verify native execution |
| `python3 tests/stack/standalone/test_stratum_port.py` | PASS, 14 tests | Same result |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` | FAIL, existing `config_defaults_reference.sh` case indentation, pinned shfmt, exit 2 | Same failure; ShellCheck passes |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML PASS; Markdown FAIL, 22 third-party cache findings, exit 2 | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |

Native checks pass: `make go-build test-go`, `go -C go vet -tags=parity ./...`,
`go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compilation only).
Generated CLI/new-adapter ShellCheck and shfmt, Go formatting, locked Ruff,
scoped Markdown and `git diff --check` pass. Source/security reviews are clean.
Scoped Markdown uses the original rules:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-render.md
```

## Network settings slice (2026-11-01)

Go derives and validates subnet, egress flags, explorer URL, remote endpoints and
pool settings. It preserves defaults, leading-zero IPv4 octets, strict remote
ports, exact diagnostics and error order. The snapshot records how many globals
changed before a verdict, including clearing all five remote fields before reads.

The new `27d-go-network-settings.sh` hook checks fixed NUL fields, assignment
count, helper exit and EOF before applying that snapshot. Missing hooks and
unsupported inputs retain Bash fallback. The original block remains in place
inside `28-parse-and-validate-config.sh`, still 412 lines. Six new comparisons
cover native execution, partial state, mode changes and malformed-helper fallback.
Existing suites and fixtures are unchanged; full Linux invalid-config proof is unavailable.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline
and `tests/go-parity/run.sh` for Go selection, with worktree caches and an absent
Docker socket. Private records use `.go-cache/logs/config-network-settings-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-network-settings-parity test-go-config-validation-parity test-go-config-defaults-parity test-go-config-document-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-caddy-parity test-go-caddy-sites-parity test-go-stratum-parity test-go-parity` | PASS, including unchanged raw parser and render fixture/goldens | Same result; native execution verified separately |
| `make test-go-network-settings-parity` (final missing-hook guard) | PASS, 6 supplementary comparisons and Go units | Same result; native execution verified |
| `python3 tests/stack/standalone/test_stratum_port.py` | PASS, 14 tests | Same result; stratum regression coverage |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | Same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | Same result; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no application Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` | FAIL, existing `config_defaults_reference.sh` case indentation, pinned shfmt, exit 2 | Same failure; ShellCheck passes |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML PASS; Markdown FAIL, 22 third-party cache findings, exit 2 | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |

Native checks pass: `make go-build test-go`, `go -C go vet -tags=parity ./...`,
`go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compilation only).
Generated CLI/new-adapter ShellCheck and shfmt, Go formatting, locked Ruff,
scoped Markdown and `git diff --check` pass. Source/security reviews are clean.
Scoped Markdown uses the original rules:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-baseline.md docs/dev/go-port/results-render.md
```

## Proxy settings and Caddy auth slice (2026-11-01)

Go parses explicit/empty stratum passwords, normalizes stratum TLS and validates
proxy donation levels, preserving rejection text and partial globals. `auto`
passwords, compound/control inputs and unsupported numbers use Bash fallback,
including existing-secret reuse and random-generation order. Five supplementary
comparison groups verify native jq avoidance, failures, state and malformed frames.

Caddy auth blocks and boot-capability SHA-256 are native through a stdin-only
NUL protocol. Noncanonical base64, decoded NUL and missing required shell state
retain Bash fallback. Host/interface discovery, bcrypt, TLS minting and writes
remain Bash. Six new comparison groups check complete files, side-effect order
and native execution. Existing suites and fixtures remain unchanged; the original
proxy and Caddy auth cases require the unavailable Linux/Docker stack harness.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline and
`tests/go-parity/run.sh` for Go selection, with worktree caches and an absent
Docker socket. Private records use `.go-cache/logs/config-proxy-caddy-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| Config/render comparisons below | PASS, including unchanged raw parser/render fixture/goldens and 5 proxy comparison groups | Same result; native execution verified separately |
| Caddy comparisons below | PASS, 6 auth, 5 renderer and 3 site comparison groups; Go units | Same result; native preparation verified |
| `make test-dashboard test-fakes test-patch-coverage` with `COMPARE=a73ffced33800de9435779a9cabef53864455acb` | PASS, 3716 dashboard/54 fake tests, 97.42% coverage; patch check not applicable | Same counts; Python backend |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` | PASS, including 891 frontend tests | Same result |
| `make test` | FAIL, existing `config_defaults_reference.sh` indentation, pinned shfmt, exit 2; ShellCheck PASS | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML PASS; Markdown FAIL, 22 third-party cache findings, exit 2 | Same result |

Config/render command: `make test-go-proxy-settings-parity test-go-config-validation-parity test-go-config-defaults-parity test-go-config-document-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-network-settings-parity test-go-stratum-parity test-go-parity`.
Caddy command: `make test-go-caddy-auth-parity test-go-caddy-parity test-go-caddy-sites-parity`.
Native race checks pass: `go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
plus `go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compile only).
Generated CLI/new-adapter ShellCheck, changed-shell shfmt, Go formatting and source/security reviews pass.
Scoped Markdown uses `npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-render.md`.
