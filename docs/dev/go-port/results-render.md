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
