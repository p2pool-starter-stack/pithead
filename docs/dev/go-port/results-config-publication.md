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
