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
