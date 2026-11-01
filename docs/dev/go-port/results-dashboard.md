# Dashboard parity results

## Dashboard HTTP foundation slice (2026-11-01)

The operator's 15:30Z priority change moves the dashboard ahead of further CLI
refinement. The credential publication slice is finished and archived above.
The immediate target is a dashboard that serves its contracts on existing and
corrupt databases; the current HTTP foundation is partial.

`make go-dashboard-build` builds `go/bin/dashboard`. It binds to the same
loopback endpoint and serves the complete application route/method table,
conditional control-route registration, security headers, HTML shell, preview
and static assets in Go. Unknown routes return 404; wrong methods return 405
with the reference Allow header. Shell caching, JavaScript MIME, file metadata,
HEAD, ranges, conditional responses and missing-file behavior have direct
Python comparisons. Preview retains its opt-in gate and no-store policy.

Every registered data/control handler still delegates to Python. A normal Go
launch starts the unchanged Python application with an inherited private
listener; it still owns state, polling, services and SQLite. An optional
reference override accepts only literal loopback HTTP addresses. Go drains
requests and terminates/reaps its own reference child. This is a hybrid server,
not a native state or storage implementation, and no performance claim is made.
The normal dashboard container command remains Python; selection is not wired.

The new pytest plugin puts Go in front of each unchanged Python app fixture and
shares its state references. It forwards fallback requests to that original
app, fails if the Go child is absent, and reaps the exact child. A test-only
restart reflects preview environment changes made after app creation. Original
Python service/view unit tests still exercise Python; a full-suite pass must
not be interpreted as native backend proof. Seven new comparisons use a sentinel
reference to prove native transport ownership and compare actual Python/Go
responses and exercise the actual Python-child bootstrap against an isolated
aiohttp stub, including signal shutdown and exact child-PID reaping. No existing
test, fixture or browser asset changes.

Baseline uses `PITHEAD_IMPL=python make test-dashboard`. Go uses the same command
with `PITHEAD_IMPL=go`, `PYTEST_PLUGINS=dashboard_http_plugin` and `PYTHONPATH`
containing the absolute `tests/go-parity` and `dashboard` directories. Runs use
worktree caches and an absent Docker socket. Private records are under
`.go-cache/logs/dashboard-http-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3716 tests, 97.42% Python coverage | Pass; same 3716 tests unchanged, 97.38% Python coverage; hybrid adapter required |
| Six unchanged shell/static/security/disabled-control/layout/preview modules named in the new Make target | Pass; 19 tests | Pass; same 19 tests unchanged |
| `make test-go-dashboard-http-parity` | Python responses compared within the supplementary cases | Pass; 19 unchanged tests and 7 new cases |
| `make test-patch-coverage` after the Go-selected dashboard suite | Not separately rerun | Pass; 97% over the branch diff; Python coverage is not Go coverage |
| `make test-fakes` | Pass; 54 tests | Pass; same 54 tests, Python client contracts |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2 at unchanged `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 third-party cache Markdown findings | Same result |

Native checks pass: `go -C go test -json -race -count=1
./internal/dashboard/...`, `go -C go test ./...`, `go -C go vet ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/dashboard-linux-amd64
./cmd/dashboard` (compile only).
The original Linux stack/container oracle remains unavailable. Actual reference
child bootstrap is tested with an inherited listener and an isolated aiohttp
application; no live stack or real collector is started. Successful migration
and corrupt-database recovery by Go remain unproven. Rare static
conditional/range combinations and precompressed sibling negotiation are not
yet covered; no precompressed assets are shipped today.

All 638 Python files pass locked Ruff lint/formatting. Dashboard extras are
restored with `uv sync --locked --project dashboard --extra dev --extra test`.
Changed Go files pass `gofmt -l`. Changed Markdown passes `npx --yes
markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs`
with the four changed document paths. Paired `make lint-file-budget
lint-docs-voice` passes after the ledger update, using the starting-SHA budget
override above.

Independent security and adversarial reviews pass after static normalization,
special-file handling and loopback-only reference checks. A real Go launch
against an isolated Python fixture proves listener inheritance, native shell,
delegated JSON, graceful parent exit and child reaping. Frozen-source checksums
confirm the final tested implementation and new comparisons remain unchanged.
Existing tests, fixtures and Make behavior are unchanged; two additive targets
build and test the dashboard. The aggregate Make gate and unavailable
Linux/Docker/fleet checks retain the limits below.
