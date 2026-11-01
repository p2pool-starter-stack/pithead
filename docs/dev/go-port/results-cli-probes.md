# CLI probe parity results (2026-10-31)

Detailed results linked from the [parity ledger](PARITY.md).

## Verifier and daemon availability slice (2026-10-31)

`go/internal/doctor/release.go` ports the release-verification diagnostic: source
checkout detection, public-key presence, Docker availability, and cached verifier
image findings. It preserves regular-file and symlink behavior and checks Docker
regardless of the selected engine. It never runs the verifier or pulls an image.
`go/internal/doctor/daemon.go` ports Docker/Podman reachability, including missing
Docker's info finding, engine precedence and appliance wording.

These are native package ports; the production doctor collector still executes
Bash. Unsupported shell-script launches and relative executable discovery return
`ErrUnsupportedProbeInput` without a finding. The first new comparison exposed
that `exec.LookPath` searches before `Cmd.Dir` takes effect; release probing now
declines relative PATH entries after its source/no-key short circuits. The new
adapter's source boundaries are checked so an upstream edit fails the test.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Verifier/daemon findings | `PITHEAD_IMPL=bash make test-go-doctor-verification-parity`: PASS, 4 paired groups plus Go units | `tests/go-parity/run.sh make test-go-doctor-verification-parity`: PASS, same groups and units |
| CLI and doctor JSON regressions | `PITHEAD_IMPL=bash make test-go-doctor-parity test-go-parity`: PASS, 13 + 12 paired groups | `tests/go-parity/run.sh make test-go-doctor-parity test-go-parity`: PASS, same groups |

The other consolidated checks reran with the same results; commands are recorded
above and each arm's private logs are identified below.

The consolidated Go race, tagged vet and Linux build commands pass (24 tagged
comparison groups plus units). Adapter syntax, pinned ShellCheck/shfmt and scoped
Markdown checks pass. Independent static review found no remaining defects.
The unchanged shell-suite commands still refuse macOS (exit 2). Private command
and exit records use `.go-cache/logs/verification-*`. Existing tests/checks remain
unchanged; no download, Git write or live probe occurred.

## Control-unit and local-miner slice (2026-10-31)

`go/internal/doctor/control.go` ports unit-directory selection, owner extraction
and the control-channel finding. It compares physical install paths, preserves
missing owner suffixes, distinguishes missing units and foreign spools, and keeps
the superseded rollback-directory guard. It discovers systemctl without executing
it. `go/internal/doctor/local_miner.go` ports the appliance's reduced-HugePages
warning using the existing reservation parser. Getter values are inputs; general
`.env` and config parsing and production collection still use Bash.

The paired cases cover section headings, exact TSV/human findings, appliance
wording, bool normalization, symlink/current/versioned paths, deleted owners,
custom egress units, marker tiers and silent gates. Parent-directory components,
multiline paths, relative executable lookup, sed metacharacters and NUL inputs
decline a native verdict. Safe relative unit directories resolve from the install.
Comparisons exposed Bash's trailing-newline trimming and NUL stripping warning;
the checked marker parser now returns unsupported on NUL lines so memory and
local-miner collection can preserve the Bash diagnostic through fallback.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Control units and miner gate | `PITHEAD_IMPL=bash make test-go-doctor-control-parity`: PASS, 9 tagged groups plus Go units | `tests/go-parity/run.sh make test-go-doctor-control-parity`: PASS |
| File budget, build guards, docs voice, paths and operator strings | `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb PITHEAD_IMPL=bash make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings`: PASS | Same base with `tests/go-parity/run.sh make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings`: PASS |

The other consolidated checks reran with the same results; commands are recorded
above and each arm's private logs are identified below.

The consolidated Go race, tagged vet and Linux build commands pass (33 tagged
comparison groups plus units). Adapter syntax, pinned ShellCheck/shfmt and scoped
Markdown checks pass. Independent static review found no remaining defects.
The shell suite still refuses macOS in both modes. Private command/exit records
use `.go-cache/logs/control-*`. Existing tests/checks remain unchanged; no download,
Git write, systemd call, Docker daemon or bench was used.

## Grouped disk slice (2026-10-31)

`go/internal/doctor/disk.go` ports component budgets, nearest-existing-ancestor
resolution and per-filesystem grouping shared by doctor and setup preflight.
It preserves component order, remote-component omission, the 528 GiB combined
budget, unknown-capacity behavior and preflight's warning-only output. Env/config
getters and production callers still use Bash. Relative data paths resolve from
the supplied install directory. Unsupported path/tool inputs and failed capacity
reads decline a native verdict so a future collector can retain Bash behavior.
Go retains df, awk and dirname calls to preserve their output and failure paths.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Disk, CLI and doctor JSON | `PITHEAD_IMPL=bash make test-go-doctor-disk-parity test-go-doctor-parity test-go-parity`: PASS, 8 disk + 13 JSON + 12 CLI groups and Go units | `tests/go-parity/run.sh make test-go-doctor-disk-parity test-go-doctor-parity test-go-parity`: PASS |

The other consolidated checks reran with the same results; commands are recorded
above and each arm's private logs are identified below.

The consolidated Go race, tagged vet and Linux build commands pass (41 tagged
comparison groups plus units). Adapter syntax, pinned ShellCheck/shfmt and scoped
Markdown checks pass. The integer parser now matches Bash's ASCII whitespace
handling. Independent static review found no remaining defects. Final parity logs
use `.go-cache/logs/storage-final-parity-*`, race/vet/build use `storage-reviewed-*`,
and other command/exit records use `storage-*`. Existing tests/checks remain
unchanged; no Git write, download, live disk probe or daemon contact occurred.

## Missing-data and deployment slice (2026-10-31)

`data_directories.go` ports missing-data enumeration, doctor findings and the
relocated-install warning bodies. `deployment.go` ports environment-file and
setup-completion findings. Both preserve literal `true` gating, getter newline
trimming, variable order, symlinks, relative paths and DIY/appliance wording.
Inputs are getter outputs; dotenv parsing and production callers remain Bash.
Unsupported paths/NUL values and warning escapes decline a native verdict.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Data/deployment, CLI and JSON | `PITHEAD_IMPL=bash make test-go-doctor-data-parity test-go-doctor-parity test-go-parity`: PASS, 8 + 13 + 12 paired groups and Go units | `tests/go-parity/run.sh make test-go-doctor-data-parity test-go-doctor-parity test-go-parity`: PASS |

The other consolidated commands reran with the same results.

Additional checks pass: `go -C go test -tags=parity -race -count=1 ./internal/doctor`
(49 tagged comparison groups plus units), `go -C go vet -tags=parity ./...` and
the Linux build command above. Cross-compilation provides no Linux runtime
verdict. New adapter syntax, pinned ShellCheck/shfmt, scoped Markdown and Go
formatting checks pass. Independent static review found no remaining defects.
Current private command/exit records use `.go-cache/logs/stale-*`.
The first Go full gate also caught an extra ledger blank line; it was corrected
before the rerun recorded as `stale-gate-final-go`.
Existing tests, fixtures, goldens, lint rules and Make checks remain unchanged;
no Git write, download, live probe or daemon contact occurred.

## Tor address slice (2026-10-31)

`go/internal/doctor/onion_addresses.go` ports the ordered node/dashboard report,
exact profile gates, placeholder handling and key-specific appliance remedies.
`go/internal/onion/` shares missing-address detection and dashboard text with native
status while preserving its getter order. Getter outputs are inputs; doctor
collection and dotenv parsing remain Bash. No address validation was added.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Tor addresses, status, JSON and CLI | `PITHEAD_IMPL=bash make test-go-doctor-onion-parity test-go-status-parity test-go-doctor-parity test-go-parity`: PASS, 8 + 9 + 13 + 12 paired groups and Go units | `tests/go-parity/run.sh make test-go-doctor-onion-parity test-go-status-parity test-go-doctor-parity test-go-parity`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard and fake daemons | `PITHEAD_IMPL=python make test-dashboard` and `PITHEAD_IMPL=python make test-fakes`: PASS, 3716 tests/97.42% and 54 tests | `tests/go-parity/run.sh make test-dashboard` and `tests/go-parity/run.sh make test-fakes`: PASS, same counts/coverage; backend remains Python |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: same result |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |

Additional checks pass: `go -C go test -tags=parity -race -count=1
./internal/doctor ./internal/status ./internal/onion` (57 tagged doctor comparison
groups plus units), `go -C go vet -tags=parity ./...` and the Linux build command
above. Cross-compilation provides no Linux runtime verdict. Adapter syntax, pinned
ShellCheck/shfmt, scoped Markdown and Go formatting checks pass. Current private
command/exit records use `.go-cache/logs/onion-*`. Independent static review found
no remaining defects. Existing tests, fixtures, goldens, lint rules and Make checks
remain unchanged; no Git write, download, Tor request, live probe or daemon contact
occurred.

## Config diagnostics and payout-address slice (2026-10-31)

`go/internal/address/` ports Monero block Base58/legacy Keccak and Tari
Base58/emoji/DammSum classification, network/feature checks and public-key
extraction. `go/internal/doctor/config.go` ports SSH release policy and ordered
payout-address findings, including placeholders, getter newline trimming and
DIY/appliance wording. Inputs are config-presence and getter outputs; JSON and
variant-file parsing and the production collector remain Bash. Verification
availability is an explicit input preserving shape-only/unchecked behavior when
Python cannot run. Non-ASCII Monero doctor input declines a native verdict because
Bash shape counting depends on locale; the reusable classifier uses byte counting.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Address classifiers and config diagnostics | `PITHEAD_IMPL=bash make test-go-doctor-config-parity`: PASS, 11 tagged comparison groups and Go units | `tests/go-parity/run.sh make test-go-doctor-config-parity test-go-doctor-parity test-go-parity`: PASS |
| CLI and doctor JSON | `PITHEAD_IMPL=bash make test-go-doctor-config-parity test-go-doctor-parity test-go-parity`: PASS, initial 10 address/config groups plus 13 JSON and 12 CLI groups | Combined Go command above: PASS, 11 + 13 + 12 groups |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard and fake daemons | `PITHEAD_IMPL=python make test-dashboard` and `PITHEAD_IMPL=python make test-fakes`: PASS, 3716 tests/97.42% and 54 tests | Same Go wrapper commands: PASS, same counts/coverage; backend remains Python |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: same result |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

Additional checks pass: `go -C go test -tags=parity -race -count=1
./internal/doctor ./internal/address`, `go -C go vet -tags=parity ./...` and the
Linux build command above. After the locale correction, `go -C go test -race
-count=1 ./internal/address`, `go -C go test -tags=parity -race -count=1 -run
TestConfigMoneroByteShape ./internal/doctor` and `go -C go test -count=1 ./...`
pass. The new byte-shape group also passes in both modes with `PITHEAD_IMPL=bash
go -C go test -tags=parity -count=1 -run TestConfigMoneroByteShape
./internal/doctor` and the same command through `tests/go-parity/run.sh`.
Cross-compilation provides no Linux runtime verdict. Adapter syntax, pinned
ShellCheck/shfmt, Go formatting and scoped Markdown checks pass.
Comparisons caught and corrected a missing word in the appliance Tari message;
review caught and corrected direct Monero shape counting under the C locale.
Independent static review now passes with no remaining defects. Private
command/exit records use `.go-cache/logs/config-*`. Existing tests, fixtures,
goldens, lint rules and Make checks remain unchanged; no Git write, download,
network request, live probe or daemon contact occurred.

[Back to the parity ledger](PARITY.md)
