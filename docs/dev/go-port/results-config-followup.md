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

## CPU and peer resource render slice (2026-11-01)

Go computes supported automatic block-preparation thread counts from supplied
core facts and validates outbound-peer bounds. Bash retains config/hardware
reads, callback order, `.env` publication and compatibility fallback for
unsupported arithmetic and integer-overflow behavior. Fingerprint and TLS-path
reads remain Bash. Main verbs and parser orchestration remain Bash; the dashboard
remains Python.

Baseline commands use `PITHEAD_IMPL=bash`; Go uses `tests/go-parity/run.sh`.
Worktree caches and an absent Docker socket isolate the runs. Private records
use `.go-cache/logs/env-resources-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-env-resources-parity` including unchanged memory comparisons | Pass; 7 existing and 8 new methods | Same result |
| Affected config/render comparisons below | Pass; unchanged parser and render goldens included | Same result |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2: existing `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make test-stack` | Exit 2: macOS refusal | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 cache Markdown findings | Same result |

Affected config/render command: `make test-go-env-network-parity test-go-env-parity test-go-config-document-parity test-go-parity`.
Native checks pass: `go -C go test -json -tags=parity -race -count=1
./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64
./cmd/pithead` (compile only).

Changed Go files pass `gofmt -l`. Changed shell files pass `shfmt -i 4 -d`;
`shellcheck -x --severity=warning pithead tests/go-parity/env_resources_reference.sh`
passes. The new Python comparison passes locked `ruff check` and
`ruff format --check` through `uv run --locked --project dashboard --extra dev`.
Dashboard test extras are restored with
`uv sync --locked --project dashboard --extra dev --extra test`.
Changed Markdown passes `npx --yes markdownlint-cli2@0.18.1 --config
.config/.markdownlint-cli2.jsonc --no-globs` with the four changed document paths;
`make lint-file-budget lint-docs-voice` passes after the final ledger update with
the starting-SHA budget override above.

Native core facts use canonical signed integers whose subtraction is supported;
other arithmetic forms and integer overflow retain Bash behavior. Configured
numeric prep-thread values bypass hardware discovery, and leading-zero peer
strings remain byte-identical in `.env`. Helper inputs include a producer-status
footer; malformed input, output or helper failures fall back before assigning
thread state. Independent source and comparison reviews found no remaining defect.

Existing tests and fixtures remain unchanged. The original Linux CLI harness and
Docker-backed parser checks remain unavailable locally. Dashboard, fake-daemon
and patch-coverage suites are not rerun for this CLI-only change; earlier paired
results remain in the linked ledger.

## Parser input validation slice (2026-11-01)

Go performs the parser's opening document, webhook and control-character checks
from one supported JSON read, preserving the first reported error. Bash retains
callbacks and later parser orchestration. Missing dependencies, unsupported JSON,
nonregular or leading-dash paths, producer failures and malformed helper responses
retain the full original Python/jq sequence. Those fallback calls temporarily
disable native helpers so they cannot re-enter and alter reference diagnostics.
Main verbs remain Bash; the dashboard remains Python.

Baseline commands use `PITHEAD_IMPL=bash`; Go uses `tests/go-parity/run.sh`.
Worktree caches and an absent Docker socket isolate the runs. Private records
use `.go-cache/logs/config-input-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-input-parity` including unchanged validation/document suites | Pass; 9 new methods and 7 original parser tests | Same result |
| Affected config/render comparisons below | Pass; unchanged render fixture/goldens included | Same result |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2: existing `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make test-stack` | Exit 2: macOS refusal | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 cache Markdown findings | Same result |

Affected config/render command: `make test-go-wallet-settings-parity test-go-payout-ownership-parity test-go-env-parity test-go-caddy-parity test-go-parity`.
Both final core runs passed: private records use `baseline-core-final` and
`go-core-final`. The initial Go run found inherited `BASH_ENV` overriding fake
helper selection in the new comparison harness. Removing that inherited hook
from its child environments fixed isolation; assertions and existing tests were
unchanged, and the complete paired core command was rerun.

Native checks pass: `go -C go test -json -tags=parity -race -count=1
./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64
./cmd/pithead` (compile only).

Changed Go files pass `gofmt -l`. Changed shell files pass `shfmt -i 4 -d`;
`shellcheck -x --severity=warning pithead tests/go-parity/config_input_reference.sh`
passes. The final Python comparison passes locked `ruff check` and
`ruff format --check` through the unchanged global Python lint target.
Dashboard test extras are restored with
`uv sync --locked --project dashboard --extra dev --extra test`.
Changed Markdown passes `npx --yes markdownlint-cli2@0.18.1 --config
.config/.markdownlint-cli2.jsonc --no-globs` with the four changed document paths;
`make lint-file-budget lint-docs-voice` passes after the final ledger update with
the starting-SHA budget override above.

The new helper accepts configuration only on stdin with a producer-status footer.
It emits a fixed validation stage and the existing diagnostic reason; secret
values remain absent from argv and diagnostics. Independent source, security and
comparison reviews found no remaining defect.

Existing tests and fixtures remain unchanged. Full Linux CLI and Docker-backed
parser checks remain unavailable locally; Go's Linux build is compile-only.
Dashboard, fake-daemon and patch-coverage suites are not rerun for this CLI-only
change; earlier paired results remain in the linked ledger.
