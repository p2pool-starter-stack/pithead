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

## Config version policy and stamping slice (2026-11-01)

Go validates supported release versions, computes stamp policy and renders ordered stamped JSON. Bash
retains VERSION reads, dry-run checks, warnings, ownership/mode handling and atomic file promotion.
Unsupported JSON rewrites, including floating-point values, keep the jq fallback.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline and `tests/go-parity/run.sh` for Go, with worktree caches and an absent Docker socket.
Private records use `.go-cache/logs/config-version-*`; full Linux CLI proof remains unavailable.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-version-parity` | PASS, 16 supplementary comparison tests and Go units | Same result; native helpers verified without jq for supported input |
| Additional config/render comparisons below | PASS, including unchanged raw parser and render fixture/goldens | Same result; native helpers verified separately |
| `make test-dashboard test-fakes test-patch-coverage` with `COMPARE=a73ffced33800de9435779a9cabef53864455acb` | PASS, 3716 dashboard/54 fake tests, 97.42% coverage; patch check not applicable | Same counts; Python backend |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` | PASS, structural/documentation gates and 891 frontend tests | Same result |
| `make test` | FAIL, existing `config_defaults_reference.sh` indentation, pinned shfmt, exit 2; ShellCheck PASS | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |
| `make lint-py lint-js lint-yaml lint-md` | Python, JS and YAML pass; Markdown fails on 22 findings in third-party uv-cache files, exit 2 | Same result |

Additional config/render command: `make test-go-config-validation-parity test-go-config-defaults-parity test-go-config-document-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-network-settings-parity test-go-stratum-parity test-go-proxy-settings-parity test-go-dashboard-access-parity test-go-dashboard-auth-parity test-go-directories-parity test-go-caddy-bind-parity test-go-payout-settings-parity test-go-wallet-settings-parity test-go-site-names-parity test-go-config-access-parity test-go-caddy-auth-parity test-go-caddy-parity test-go-caddy-sites-parity test-go-parity`.
Native checks PASS: `go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compile only).
Independent source and transaction/secrecy reviews found no product defects. Go formatting, changed-shell shfmt, generated CLI/new-adapter ShellCheck and new Python Ruff checks PASS. Scoped Markdown PASS: `npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/adapters.md docs/dev/go-port/results-render-followup.md`.

An additional `/bin/bash -c 'PATH="/bin:/usr/bin:$PATH" python3 tests/go-parity/test_config_version.py'` check exits 1: the unchanged prelude requires `BASHPID`, absent in Bash 3.2. Both selections fail before the version functions; no Bash 3.2 parity is claimed.

## Config migration slice (2026-11-01)

Go plans supported legacy worker/XvB migrations and removal of Telegram control,
with ordered JSON transforms. Bash retains conflict callbacks, dry-run checks,
backups, warnings, ownership/mode handling and file promotion. Floating-point
values, duplicate keys and unsupported container shapes keep the jq fallback.
The original migration suites still need Linux.

Commands use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as baseline and
`tests/go-parity/run.sh` for Go, with worktree caches and an absent Docker socket.
Private records use `.go-cache/logs/config-migrations-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-migrations-parity` | PASS, 14 migration/static comparison tests and 2 protocol tests; Go units | Same result; supported native helpers verified without jq |
| Additional config/render comparisons below | PASS, including unchanged raw parser and render fixture/goldens | Same result; native helpers verified separately |
| `make test-dashboard test-fakes test-patch-coverage` with `COMPARE=a73ffced33800de9435779a9cabef53864455acb` | PASS, 3716 dashboard/54 fake tests, 97.42% coverage; patch check not applicable | Same counts; Python backend |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` | PASS, structural/documentation gates and 891 frontend tests | Same result |
| `make test` | FAIL, existing `config_defaults_reference.sh` indentation, pinned shfmt, exit 2; ShellCheck PASS | Same result |
| `make test-stack` | macOS refusal, exit 2 | Same refusal; no bypass |
| `make lint-py lint-js lint-yaml lint-md` | Python, JS and YAML pass; Markdown fails on 22 findings in third-party uv-cache files, exit 2 | Same result |

Additional config/render command: `make test-go-config-validation-parity test-go-config-defaults-parity test-go-config-document-parity test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-network-settings-parity test-go-stratum-parity test-go-proxy-settings-parity test-go-dashboard-access-parity test-go-dashboard-auth-parity test-go-directories-parity test-go-caddy-bind-parity test-go-payout-settings-parity test-go-wallet-settings-parity test-go-site-names-parity test-go-config-access-parity test-go-config-version-parity test-go-caddy-auth-parity test-go-caddy-parity test-go-caddy-sites-parity test-go-parity`.
Native checks PASS: `go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compile only).
Source and security reviews, Go formatting, changed-shell shfmt, generated CLI/new-adapter ShellCheck and new Python Ruff checks PASS. Scoped Markdown PASS: `npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs docs/dev/go-port/PARITY.md docs/dev/repo-map.md docs/dev/go-port/adapters.md docs/dev/go-port/results-render-followup.md`.

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
