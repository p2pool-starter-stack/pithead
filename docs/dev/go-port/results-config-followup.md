# Later configuration results

Detailed parity results for later configuration slices.

## Payout ownership validation slice (2026-11-01)

Go validates supplied decoded payout identities against the configured private
view keys, preserving the diagnostic order and Tari spend-key assignment before
an explicit-key mismatch. Bash retains address decoding, callbacks and
compatibility fallback. Missing Python, non-ASCII decoded identities and helper
failures retain the reference path. Main verbs, parser orchestration and render transactions
remain Bash; the dashboard remains Python.

Baseline commands use `PITHEAD_IMPL=bash`; Go uses `tests/go-parity/run.sh`.
Worktree caches and an absent Docker socket isolate the runs. Private records
use `.go-cache/logs/payout-ownership-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-payout-ownership-parity` including unchanged payout-key comparisons | Pass; 8 existing and 9 new methods | Same result |
| Affected config/render comparisons below | Pass; unchanged parser and render goldens included | Same result |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2: existing `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make test-stack` | Exit 2: macOS refusal | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 cache Markdown findings | Same result |

Affected config/render command: `make test-go-payout-settings-parity test-go-wallet-settings-parity test-go-env-parity test-go-caddy-parity test-go-config-document-parity test-go-parity`.
Native checks pass: `go -C go test -json -tags=parity -race -count=1
./internal/config ./internal/cli ./internal/payoutkeys`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64
./cmd/pithead` (compile only).

Changed Go files pass `gofmt -l`. Changed shell files pass `shfmt -i 4 -d`;
`shellcheck -x --severity=warning pithead tests/go-parity/payout_ownership_reference.sh`
passes. The new Python comparison passes locked `ruff check` and
`ruff format --check` through `uv run --locked --project dashboard --extra dev`.
Dashboard test extras are restored with
`uv sync --locked --project dashboard --extra dev --extra test`.
Changed Markdown passes `npx --yes markdownlint-cli2@0.18.1 --config
.config/.markdownlint-cli2.jsonc --no-globs` with the four changed document paths;
`make lint-file-budget lint-docs-voice` passes after the final ledger update with
the starting-SHA budget override above.

The native helper receives private scalars on stdin and emits only public spend
keys and fixed diagnostics. Independent implementation and comparison reviews
found no remaining correctness or security defect after the non-ASCII fallback fix.

The existing tests and fixtures remain unchanged. The full original
payout-wallet-pairs suite requires the Linux harness and remains unavailable
locally. Dashboard, fake-daemon and patch-coverage suites are not rerun for this
CLI-only change; earlier paired results remain in the linked ledger.
