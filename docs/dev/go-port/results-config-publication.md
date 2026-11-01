# Configuration publication results

Detailed parity results for configuration file publication.
Earlier results are in the [later configuration ledger](results-config-followup.md).

## Environment file publication slice (2026-11-01)

Go writes the native dotenv body plus exactly one final newline to supported
regular targets. It truncates in place, retaining existing inodes, owners and
hard links. New files are created with mode 0600 under the existing subshell's
umask. Bash retains the final mandatory chmod, serialization compatibility
fallback and file-write diagnostics. Symlinks, special files, absent parents and
interposed cat commands keep the reference heredoc path.

The unchanged render fixture/goldens pass with Go selection. A new spy case
proves that fixture invokes the native formatter and writer successfully, each
with zero argv. Supplementary
comparisons cover literal bytes, final-newline handling, inode and hard-link
identity, symlink following through fallback, umask, error traps, mandatory chmod
and helper/tool failure. Existing CLI and parser suites remain the oracle;
original Linux lifecycle/config suites are still unavailable locally. Render/apply
orchestration otherwise stays Bash and the dashboard remains Python.

Baseline uses `PITHEAD_IMPL=bash`; Go uses `tests/go-parity/run.sh`. Runs use
worktree caches and an absent Docker socket. Private records are under
`.go-cache/logs/env-write-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-env-write-parity` | Pass; 11 new methods, unchanged env/render comparisons and 12-group CLI suite, plus Go units | Same result |
| Other core comparisons below | Pass; unchanged 7-test raw-parser suite, Caddy and Tari publication comparisons included | Same result |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2: existing `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make test-stack` | Exit 2: macOS refusal | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 cache Markdown findings | Same result |

The combined core command was `make test-go-env-write-parity
test-go-config-input-parity test-go-caddy-parity test-go-tari-secret-parity`.
Private records are `baseline-core` and `go-core`; paired gate, aggregate, stack
and lint records use the corresponding suffixes.
Native checks pass: `go -C go test -json -tags=parity -race -count=1
./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64
./cmd/pithead` (compile only).

Changed Go files pass `gofmt -l`; changed shell files pass `shfmt -i 4 -d`.
`shellcheck -x --severity=warning pithead tests/go-parity/env_write_reference.sh`
passes. Locked Ruff checks and formatting pass for all 632 Python files through
`make lint-py`; dashboard extras are restored with `uv sync --locked --project
dashboard --extra dev --extra test`.
Changed Markdown passes `npx --yes markdownlint-cli2@0.18.1 --config
.config/.markdownlint-cli2.jsonc --no-globs` with the four changed document paths;
`make lint-file-budget lint-docs-voice` passes after the final ledger update with
the starting-SHA budget override above.

Independent security and adversarial reviews found no remaining defect. A
frozen-source checksum audit confirms the tested implementation and comparisons
are unchanged after validation. Existing tests, fixtures and Make behavior remain
unchanged; the new target adds supplementary coverage and existing dependencies.
Earlier Tari publication results are preserved in the linked configuration ledger.
Original Linux lifecycle/config suites remain unavailable locally. Dashboard,
fake-daemon and patch-coverage suites are not rerun for this CLI-only change;
earlier paired results remain in the linked ledgers.

## Tari secret ownership repair slice (2026-11-01)

The new `config-tari-secret-owned` helper can repair the temporary file's UID and GID with
an fd-based chown when permitted. It verifies both before publishing by rename.
Matching UID still ignores GID, including its sentinel value, as Bash does.
Ownership failure or unsupported IDs remove the temporary file with mode 0600 and
leave the prior destination intact before Bash retries its original chown/sudo
path. Tool interposition, dry-run and directory guards retain their reference
behavior. The existing strict Go API and private helper remain same-UID-only.

On this unprivileged host, supplementary comparisons prove matching-UID native
publication, owned-helper selection with zero argv, protocol refusals, sentinel
refusals, failed foreign-UID cleanup and the unchanged sudo fallback. The sudo
fixture is a local failure stub. Privilege-dependent tests are conditional: successful
foreign-UID chown, its verification and final publication are not proven locally.
The unchanged render fixture/goldens, parser and CLI suites remain the oracle;
mocked ownership commands in the render fixture select compatibility fallback.
Original Linux ownership/lifecycle suites are still unavailable. Main verb
operations remain Bash and the dashboard remains Python.

Baseline uses `PITHEAD_IMPL=bash`; Go uses `tests/go-parity/run.sh`. Runs use
worktree caches and an absent Docker socket. Private records are under
`.go-cache/logs/tari-owner-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-tari-ownership-parity` | Pass; 6 new methods, prior Tari/env comparisons, render fixture/goldens and 12-group CLI suite, plus Go units | Same result |
| `make test-go` repeated after portable ownership assertions | Pass; portable ownership assertions included | Same result |
| `make test-go-config-input-parity test-go-caddy-parity` | Pass; unchanged 7-test raw-parser suite and supplementary parser/Caddy comparisons | Same result |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2: existing `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make test-stack` | Exit 2: macOS refusal | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at cache Markdown findings | Same result |

The paired core command combined all three targets above. Native checks pass:
`go -C go test -json -tags=parity -race -count=1 ./internal/config ./internal/cli`,
`go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build
-o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` (compile only).

Changed Go files pass `gofmt -l`; the changed shell hook passes `shfmt -i 4 -d`.
`shellcheck -x --severity=warning pithead` passes. Security review found no
remaining defect; adversarial review identified the unexecuted privileged
success path as the proof limit recorded above.

The final paired lint run reports 22 third-party cache Markdown findings. Its
initial run also read a private Markdown audit copy; that copy now has a text
extension, and the unchanged lint command was repeated. Locked Ruff lint and
formatting pass for all 634 Python files. Dashboard extras are restored with
`uv sync --locked --project dashboard --extra dev --extra test`.

Changed Markdown passes `npx --yes markdownlint-cli2@0.18.1 --config
.config/.markdownlint-cli2.jsonc --no-globs` with the four changed document paths.
Paired `make lint-file-budget lint-docs-voice` passes after the ledger update
with the starting-SHA budget override above.

Existing tests, fixtures and Make behavior remain unchanged. The new target
adds supplementary coverage and existing dependencies; implementation and new
test checksums remain frozen after validation. Earlier env publication results
are preserved in the linked publication ledger. Dashboard, fake-daemon and
patch-coverage suites are not rerun for this CLI-only change; earlier paired
results remain in the linked ledgers.

## Config-version publication slice (2026-11-01)

Go now publishes supported version stamps through a unique sibling temporary
file. It uses the existing ordered JSON transform, retains the source path's
lstat UID/GID, applies mode 0600, always attempts chown, verifies metadata and
closes before rename. A successful rename is the final fallible operation.
Pre-publication failures remove the temporary file before the original Bash
transaction retries. Warnings and the caller's dry-run/no-change gates remain Bash; existing Go
version planning and formatting are reused. Other config writers and verb
operations remain Bash.

The existing `config-version` helper accepts publication frames with zero argv;
its named scalar/document operations retain their existing contracts. The
unchanged 16-method version suite passes with the new writer reachable through
its existing sourced hook. Supplementary comparisons prove actual native
success, exact bytes, mode/owner, inode replacement, symlink replacement,
hard-link separation, protocol/tool fallback and no-op behavior. A local
symlink with a different group from its target confirms lstat ownership; BSD
and GNU stat probes agree. No successful foreign-UID ownership change is
claimed from this unprivileged host.

Caller umasks that suppress owner-write permission retain Bash: its mktemp file
would otherwise fail when reopened by the writer, whereas Go holds an open fd.
A five-line adapter only sets that caller umask before executing the unchanged
version reference adapter. New comparisons normalize temporary names, private
paths and Bash diagnostic line numbers; existing tests and goldens are unchanged.
The original Linux config/lifecycle suite is still unavailable. The dashboard
remains Python.

Baseline uses `PITHEAD_IMPL=bash`; Go uses `tests/go-parity/run.sh`. Runs use
worktree caches and an absent Docker socket. Private records are under
`.go-cache/logs/version-publish-*`.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-config-version-publish-parity` | Pass; unchanged 16-method version suite, 7 new methods, prior env/render comparisons and 12-group CLI suite, plus Go units | Same result |
| `make test-go-config-input-parity test-go-caddy-parity` | Pass; unchanged 7-test raw-parser suite and supplementary parser/Caddy comparisons | Same result |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings test-frontend` with `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb` | Pass; 891 frontend tests | Same result |
| `make test` | Exit 2: existing `config_defaults_reference.sh` shfmt finding; ShellCheck passes | Same result |
| `make test-stack` | Exit 2: macOS refusal | Same refusal |
| `make lint-py lint-js lint-yaml lint-md` | Python/JS/YAML pass; exit 2 at 22 third-party cache Markdown findings | Same result |

The paired core command combined all three targets above. The seven new
comparison methods were repeated after adding the different-group symlink case
with `python3 tests/go-parity/test_config_version_publish.py` in both modes.
Native checks pass: `go -C go test -json -tags=parity -race -count=1
./internal/config ./internal/cli`, `go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64
./cmd/pithead` (compile only).

Changed Go files pass `gofmt -l`; changed shell files pass `shfmt -i 4 -d`.
`shellcheck -x --severity=warning pithead
tests/go-parity/config_version_publish_reference.sh` passes. Locked Ruff lint
and formatting pass for all 635 Python files through `make lint-py`; dashboard
extras are restored with `uv sync --locked --project dashboard --extra dev
--extra test`.

Changed Markdown passes `npx --yes markdownlint-cli2@0.18.1 --config
.config/.markdownlint-cli2.jsonc --no-globs` with the four changed document paths.
Paired `make lint-file-budget lint-docs-voice` passes after the ledger update
with the starting-SHA budget override above.

Independent security and adversarial reviews found no remaining defect.
Frozen-source checksums confirm the tested implementation and new comparisons
remain unchanged after validation. Existing tests, fixtures and Make behavior
remain unchanged; the new target adds supplementary coverage and existing
dependencies. Earlier Tari publication results are preserved in the linked
publication ledger. Dashboard, fake-daemon and patch-coverage suites are not
rerun for this CLI-only change; earlier paired results remain in the linked
ledgers.
