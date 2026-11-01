# Later render parity results

Recorded render-slice commands, results and limitations for issue #3811.

## Shared site-name and SAN slice (2026-11-01)

Go filters Bash-collected tokens into supported auto-expanded Caddy/certificate host lists and formats
certificate SANs. Bash retains base selection, discovery, shell expansion and compatibility fallback.
New comparisons cover ordering, filtering, framing and rendered Caddyfiles; original Linux proof remains unavailable.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline and `tests/go-parity/run.sh` for Go, with worktree caches and an absent Docker socket.
Private records use `.go-cache/logs/site-names-*`; full Linux CLI proof remains unavailable.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-site-names-parity` | PASS, 10 paired groups and 7 complete-Caddy scenarios; Go units | Same result; native expansion/SAN helpers verified |
| Additional config/render comparisons below | PASS, including unchanged raw parser and render fixture/goldens | Same result; native helpers verified separately |
| `make test-dashboard test-fakes test-patch-coverage` with `COMPARE=a73ffced33800de9435779a9cabef53864455acb` | PASS, 3716 dashboard/54 fake tests, 97.42% coverage; patch check not applicable | Same counts; Python backend |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` | PASS, structural/documentation gates and 891 frontend tests | Same result |
| `make test` | FAIL, existing `config_defaults_reference.sh` indentation, pinned shfmt, exit 2; ShellCheck PASS | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |
| `make lint-py lint-js lint-yaml lint-md` | Python, JS and YAML pass; Markdown fails on 22 findings in third-party uv-cache files, exit 2 | Same result |

Additional config/render command: `make test-go-config-validation-parity test-go-config-defaults-parity test-go-config-document-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-network-settings-parity test-go-stratum-parity test-go-proxy-settings-parity test-go-dashboard-access-parity test-go-dashboard-auth-parity test-go-directories-parity test-go-caddy-bind-parity test-go-payout-settings-parity test-go-wallet-settings-parity test-go-caddy-auth-parity test-go-caddy-parity test-go-caddy-sites-parity test-go-parity`.
Native checks PASS: `go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compile only).
Source/security reviews, Go formatting, changed-shell shfmt, generated CLI/new-adapter ShellCheck and new Python Ruff checks PASS. Scoped Markdown PASS: `npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/results-render.md`.

## SSH and node credential settings slice (2026-11-01)

Go validates supported SSH policy and parses RPC passwords with credential-generation decisions. Bash
retains the username read, appliance discovery, generation, persistence, logging and compatibility fallback.
The username read preserves the unchanged proxy adapter's extraction boundary; Go receives that result.
New comparisons cover partial state, callback order, strict framing and complete renders.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline and `tests/go-parity/run.sh` for Go, with worktree caches and an absent Docker socket.
Private records use `.go-cache/logs/config-access-*`; full Linux CLI proof remains unavailable.
Initial paired additional-comparison runs failed at the proxy extraction boundary (exit 2); final reruns below follow its repair, with tests unchanged.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-access-parity` | PASS, 10 paired groups and 3 complete-render groups; Go units | Same result; native SSH/password/plan helpers verified |
| Additional config/render comparisons below | PASS after boundary repair, including unchanged raw parser and render fixture/goldens | Same result; native helpers verified separately |
| `make test-dashboard test-fakes test-patch-coverage` with `COMPARE=a73ffced33800de9435779a9cabef53864455acb` | PASS, 3716 dashboard/54 fake tests, 97.42% coverage; patch check not applicable | Same counts; Python backend |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` | PASS, structural/documentation gates and 891 frontend tests | Same result |
| `make test` | FAIL, existing `config_defaults_reference.sh` indentation, pinned shfmt, exit 2; ShellCheck PASS | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |
| `make lint-py lint-js lint-yaml lint-md` | Python, JS and YAML pass; Markdown fails on 22 findings in third-party uv-cache files, exit 2 | Same result |

Additional config/render command: `make test-go-config-validation-parity test-go-config-defaults-parity test-go-config-document-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-network-settings-parity test-go-stratum-parity test-go-proxy-settings-parity test-go-dashboard-access-parity test-go-dashboard-auth-parity test-go-directories-parity test-go-caddy-bind-parity test-go-payout-settings-parity test-go-wallet-settings-parity test-go-site-names-parity test-go-caddy-auth-parity test-go-caddy-parity test-go-caddy-sites-parity test-go-parity`.
Native checks PASS: `go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compile only).
Source/security reviews, Go formatting, changed-shell shfmt, generated CLI/new-adapter ShellCheck and new Python Ruff checks PASS. Scoped Markdown PASS: `npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/adapters.md docs/dev/go-port/results-render-followup.md`.
