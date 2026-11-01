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

## CLI wallet classification slice (2026-11-01)

Go-selected CLI wallet classifiers use the existing native Monero and Tari
address decoders. Bash retains the parser's diagnostic cases and callback order.
The wrapper requires an exact successful Python readiness probe to preserve the
reference behavior when Python exists but cannot execute. No Python dependency
removal or performance benefit is claimed. Key-only requests, non-ASCII Monero,
invalid UTF-8 or over-4096-byte Tari inputs and helper/protocol failures retain
the original classifiers.
Main verbs and later parser orchestration remain Bash; the dashboard remains Python.

Baseline commands use `PITHEAD_IMPL=bash`; Go uses `tests/go-parity/run.sh`.
Worktree caches and an absent Docker socket isolate the runs. Private records
use `.go-cache/logs/wallet-classifiers-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-wallet-classifiers-parity` including unchanged wallet-settings/render comparisons | Pass; 9 new methods and original render fixture/goldens | Same result |
| Affected config/render comparisons below | Pass; 7 unchanged raw-parser tests included | Same result |
| Final `python3 tests/go-parity/test_wallet_classifiers.py` | Pass; 9 methods, including actual OS argument-limit fallback | Same result |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2: existing `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make test-stack` | Exit 2: macOS refusal | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 cache Markdown findings | Same result |

Affected config/render command: `make test-go-config-input-parity test-go-payout-ownership-parity test-go-caddy-parity test-go-parity`.
The final core records are `baseline-core-confirmed` and `go-core-confirmed`;
final adapter records are `baseline-adapter-confirmed` and `go-adapter-confirmed`.
Native checks pass: `go -C go test -json -tags=parity -race -count=1
./internal/cli ./internal/address ./internal/config`,
`go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64
./cmd/pithead` (compile only).

Changed Go files pass `gofmt -l`. Changed shell files pass `shfmt -i 4 -d`;
`shellcheck -x --severity=warning pithead tests/go-parity/wallet_classifiers_reference.sh`
passes after the new adapter's dynamic fixture loading was made visible to the
linter. The final Python comparison passes locked `ruff check` and
`ruff format --check` through `uv run --locked --project dashboard --extra dev
--extra test`. Dashboard test extras are retained/restored with
`uv sync --locked --project dashboard --extra dev --extra test`.
Changed Markdown passes `npx --yes markdownlint-cli2@0.18.1 --config
.config/.markdownlint-cli2.jsonc --no-globs` with the four changed document paths;
`make lint-file-budget lint-docs-voice` passes after the final ledger update with
the starting-SHA budget override above.

Helper values travel only on stdin with a producer-status footer. Malformed,
truncated, trailing or failed responses fall back before publishing a verdict.
The readiness probe preserves trailing newlines so noisy Python retains its
reference output. Oversized Tari values preserve Python's argument-execution
fallback, rather than acquiring a different verdict through stdin. Independent
source, protocol and comparison reviews found no remaining defect.

Existing tests and fixtures remain unchanged. The original Monero/Tari domain
and config-application suites require the Linux CLI harness and remain unavailable
locally. Dashboard, fake-daemon and patch-coverage suites are not rerun for this
CLI-only change; earlier paired results remain in the linked ledger.

## Lifecycle option validation slice (2026-11-01)

Go now parses the options for `render`, `apply`, `up`, `down` and `restart`
through a private stdin protocol. Bash retains error formatting, early help and
command-chain handling, deployment checks and all operational bodies. Native
selection preserves the first invalid argument, apply's partially parsed flags,
porcelain's dry-run requirement and restart's ignored trailing arguments.
No native render, apply or stack operation is claimed.

The unchanged 12-group CLI contract suite remains the runnable original oracle.
New comparisons stop at the first operational callback and compare output bytes,
exit status, callback order and caller state. A spy verifies native success at
each of the five boundaries, zero helper argv and exact stdin framing. Missing,
truncated, trailing, malformed or failed helpers retain Bash validation before
publishing state. Original Linux lifecycle tests remain unavailable on macOS;
the supplementary cases do not establish full lifecycle parity.

Baseline uses `PITHEAD_IMPL=bash`; Go uses `tests/go-parity/run.sh`. Runs use
worktree caches and an absent Docker socket. Private records are under
`.go-cache/logs/lifecycle-options-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-lifecycle-options-parity` | Pass; unchanged 12-group CLI suite, 10 new comparison methods and Go units | Same result |
| Config/render command below | Pass; unchanged 7-test raw-parser suite and render fixture/goldens included | Same result |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2: existing `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make test-stack` | Exit 2: macOS refusal | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 cache Markdown findings | Same result |

The combined core command was `make test-go-lifecycle-options-parity
test-go-config-input-parity test-go-wallet-classifiers-parity test-go-caddy-parity`.
Its private records are `baseline-core` and `go-core`; paired gate, aggregate,
stack and lint records use the corresponding suffixes.
Native checks pass: `go -C go test -json -tags=parity -race -count=1
./internal/lifecycle ./internal/cli`, `go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64
./cmd/pithead` (compile only).

Changed Go files pass `gofmt -l`. Changed shell files pass `shfmt -i 4 -d`;
`shellcheck -x --severity=warning pithead tests/go-parity/lifecycle_options_reference.sh`
passes. Locked Ruff checks and formatting pass for all 630 Python files through
`make lint-py`. Dashboard extras are restored with
`uv sync --locked --project dashboard --extra dev --extra test`.
Changed Markdown passes `npx --yes markdownlint-cli2@0.18.1 --config
.config/.markdownlint-cli2.jsonc --no-globs` with the four changed document paths;
`make lint-file-budget lint-docs-voice` passes after the final ledger update with
the starting-SHA budget override above.

Independent implementation and comparison reviews found no remaining defect.
All pre-existing tests, fixtures and Make target behavior remain unchanged;
only the new target is added. A frozen-source checksum audit confirms the tested
implementation and new comparisons are unchanged after validation. Earlier
wallet-classifier results are preserved in the linked configuration ledger.
Dashboard, fake-daemon and patch-coverage suites are not rerun for this CLI-only
change; earlier paired results remain in the linked ledgers.
