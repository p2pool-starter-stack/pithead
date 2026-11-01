# Independent review follow-up

This round addresses G9, G1, G4, G5, G6 and G10 from the operator's 2026-11-01
19:45Z review summary. The reference suites remain the oracle. Their only edit
is the explicitly requested shfmt indentation fix in the branch-added
`tests/go-parity/config_defaults_reference.sh`; `git diff -w` confirms no other
tracked test changes. Earlier reports incorrectly described that failure as
existing. It was introduced on this branch and is now fixed.

## Implementation and ownership

The new reusable `.github/workflows/go-port.yml` has a 25-minute limit and runs
both builds, all Go race units, vet, focused CLI/dashboard parity and ownership
guards. `ci.yml` adds that job; parsed comparison confirms every existing job is
unchanged. The reusable job uses the existing pinned checkout/Python/uv actions,
the local Go toolchain pin and worktree caches. No existing target changes its
behavior. Remote execution awaits the operator's commit/push.

Public unset, Bash and Python selection ignore native-helper paths. A Go-selected
fallback retains `PITHEAD_IMPL=bash`, preserving the existing CLI contract, and
carries a private hybrid marker plus the actual executable path. The launcher
consumes the marker into non-exported shell state; standalone helper adapters
can also use the marker. Explicit reference fallback removes both forms of
private state and the native helper override. Three-mode sentinels exercise the
public entrypoint, sourced parser and direct-binary fallback.

Status now retains the first stdout write error and returns 1, including errors
copying the Compose table. Stderr write errors keep Bash's exit behavior. Go's
runtime repairs an already-closed standard descriptor before application code
runs, so public `status` detects closed stdout before Go starts and uses Bash.
Unwritable open stdout and a read/write null descriptor still reach native Go.
The compatibility case is explicit; closed-stdout parity is not a native claim.

Dashboard startup waits for the child listener to answer before returning its
backend, with a 30-second deadline, bounded individual probes and early child-exit
detection. Failed startup closes the backend using the existing termination and
bounded kill sequence. An explicitly supplied reference URL keeps its previous
behavior. Delayed and failed child tests require no caller retries.

The first state request captures latest data, history, deferred storage values,
settings, metadata and one clock in its input envelope. Go forwards that envelope
with its computed results; the second phase uses a frozen reader and captured
settings. Wallet data is restricted to the three existing badge keys, and only
display prefixes enter the envelope. Payout and wallet conditional read gates
remain. Deferred earnings/XvB functions accept the captured clock; omitted
arguments preserve reference timing. History travels once through the domain
input rather than being duplicated in deferred storage.

The forced-interleaving regression changes poll/config generations and advances
past the XvB staleness boundary between phases. Live storage access is fatal in
the second phase, and the response remains coherent with the first generation.
A sequence-clock regression rejects a second clock read. A Go transport unit
checks that the first envelope is forwarded unchanged. These fixes preserve a
hybrid backend; they do not implement native polling or SQLite.

## Additive adapters and compatibility

- `test_native_ownership_guards.py` runs the unchanged seven-test parser suite in
  both modes. A wrapper records status, input size and a bounded fallback reason,
  requiring five native accepts, 97 native rejects and exactly one known deep
  document fallback. This accounts for every original parser invocation.
- Its parser mutation control copies the Go module inside the worktree cache,
  changes successful document parsing to return unsupported, and builds a mutant.
  The unchanged oracle still passes through fallback; the ownership assertion
  fails. Only the isolated copy is modified and it is removed afterward.
- The same module checks `/api/miner-connection` through the actual Go server and
  records native success or a reference fallback reason. Its route-bypass source
  mutant preserves the HTTP contract while failing the ownership assertion.
- `run_hybrid_fixture.py` supplies the new private marker only during five
  legacy internal-marker fixture methods: Caddy, lifecycle options, dotenv writes,
  Tari secret writes and wallet classifiers. Those fixtures previously used the
  public helper path alone to model internal fallback. Their suites and assertions
  stay unchanged; `make test-go-legacy-helper-parity` runs all 45 methods. Public
  selection guards run separately without that marker. Bare legacy helper targets
  still fail their obsolete marker-only setup; the additive target supplies the
  missing selection state. No method is skipped or has its expected result changed.
- `test_reference_selection.py` adds four selection groups, including sentinels
  for unset/Bash/Python and proof that internal hybrid helpers remain native.
- `test_status_closed_descriptors.py` adds five paired descriptor cases. Adjacent
  Go units check the first write failure even when later writes could succeed.
- New dashboard snapshot tests and adjacent runtime units cover interleaving,
  conditional reads, one clock, readiness and transport. They supplement the
  unchanged tests; no original test is ported or replaced.

The strict parser guard intentionally permits the original 1200-depth case's
unsupported status. Other parser compatibility inputs, including nonstandard
numbers and unsupported integer/decode boundaries, remain listed in the existing
comparison cases; this guard does not promote them to native coverage. The miner
guard separately permits unavailable bridge inputs to use Python. An unexpected
reference call for its supported input fails. Other route groups can still use
their documented fallback; this guard proves only miner-connection ownership.

## Commands and results

All commands run from the worktree root with absolute `GOCACHE`, `GOMODCACHE`,
`GOPATH` and `TMPDIR` under `.go-cache/`, `UV_CACHE_DIR` under `.uv-cache/`, and
offline local tooling. The complete CLI step is reproduced locally with
`PITHEAD_IMPL=go make test-go-parity test-go-status-parity test-go-config-document-parity test-go-env-parity test-go-legacy-helper-parity test-go-native-guards`
and passes. Complete private logs and exit metadata are under
`.go-cache/logs/dashboard-state-review-*`. No live engine or mining stack is used.

For full dashboard runs, `PYTEST_XDIST_AUTO_NUM_WORKERS=1` is set. Baseline uses
`PITHEAD_IMPL=python`; Go uses `PITHEAD_IMPL=go`,
`PYTEST_PLUGINS=dashboard_overview_plugin` and absolute `PYTHONPATH` entries for
`tests/go-parity` and `dashboard`. The 3719 tests comprise 3716 unchanged tests
and three new snapshot tests. Reference coverage uses a separate cache file.

| Command | Reference | Go selection |
|---|---|---|
| `make test-dashboard` | Pass; 3719 tests, 97.07% Python coverage | Pass; 3719 tests, 86.40% Python coverage |
| `make test-go-parity test-go-status-parity test-go-config-document-parity` | Paired reference calculations; original parser seven tests pass | Same suites pass; strict ownership also runs the original parser in Go mode |
| `make test-go-env-parity` | Paired reference renders | Pass |
| `make test-go-legacy-helper-parity` | Same five legacy helper suites and reference calculations | Pass; all 45 methods through the narrow private-marker adapter |
| `make test-go-native-guards` | Original parser and miner contracts supply the reference | Pass; source mutants are detected, selection four groups, descriptor five groups, snapshot three tests |
| `make test-go-dashboard-http-parity test-go-dashboard-state-parity test-go-dashboard-domain-parity test-go-dashboard-views-parity test-go-dashboard-fleet-parity test-go-dashboard-overview-parity` | Original calculations supply A/B expected values | Pass; 26 / 92 / 155 / 184 / 151 / 202 tests |
| `go -C go test -race -count=1 ./...`; `go -C go vet ./...` | Additive checks | Pass |
| `GOOS=linux GOARCH=amd64 go -C go build -o "$PWD/.go-cache/review-linux/" ./cmd/...` | Additive compile check | Pass; no Linux runtime claim |
| `make test-patch-coverage` after each full run | Pass; 93% | Go-only run fails at 83%; Go plus overview/fleet A/B append passes at 93% |
| `make test` | Fails at Markdown lint of third-party files in `.uv-cache/` | Same failure; shell lint now passes |
| `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | Pass with the documented starting-SHA budget base | Same project checks; no budget rule changed |
| `make test-frontend test-fakes` | Pass; 891 frontend and 54 fake-daemon tests | Pass; same counts with `PITHEAD_IMPL=go` |

Python coverage measures Python execution, not native Go. The unchanged 80% full
suite gate passes in both modes. Patch coverage is recorded separately for the
reference full run, Go full run, and combined Go plus A/B expected calculations.
The combined check appends coverage with
`PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term"`
on the overview and fleet dashboard targets before `make test-patch-coverage`.
A separate earlier run of all six focused targets also passes with A/B append. New
untracked files are outside the pre-commit diff; no gate is weakened or skipped.

Initial validation also found the bare Caddy target's obsolete marker-only
fixture; the dedicated adapter supplies private hybrid state only to the five
legacy fixture methods. Their 45-method run passes. It caught seven helper-local
declarations that initially missed the launcher's consumed private state; those
now preserve native hybrid selection.

Initial validation caught the immutable fallback test's custom reference script,
which sources the parser without the launcher; private-marker handling now
preserves that native path. Review caught a second domain clock read; it now
receives the captured clock and the new sequence test proves the fix. A fresh
adversarial review passes all six items; security review reports no exposure,
credential, process-cleanup or supply-chain finding.

## Remaining proof

Native SQLite open, schema, migrations and corrupt-database recovery are next,
with Python storage made fatal in the adapter. Existing database startup still
uses Python. Wizard/control, production selection and shipping artifacts remain
pending. G7 escape-byte parity and G8 privileged Linux proof follow those slices.
The default file-budget base and platform/Docker constraints remain in PARITY.md.
The offline zizmor workflow audit is unavailable because its pinned tool is not
in the local cache; YAML lint passes. Changed-project Markdown is checked using
the pinned tool with an ephemeral scoped config, leaving the repository rule intact.
No fleet job was submitted for this uncommitted tree; no performance claim is made.
