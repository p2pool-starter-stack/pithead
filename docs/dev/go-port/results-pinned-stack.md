# Pinned Linux stack continuation

This continuation starts at `7a1d8ad1c5f6777afe73b1da5912b20c08e3cc18`
on 2026-11-02. The 20:30Z review queue now takes precedence over the 19:25Z
stack-first order. The original pinned Linux stack command still requires both
selections and native invocation evidence. Neither full selection has a passing result yet.
The only application change is the portable bridge filter described below.

## Runner prerequisites

The normal pinned Linux ARM64 image starts the stack command as its unprivileged
user, with the original source mounted at its host path. The first reference
attempt exposes two missing prerequisites:

- The Tor-heal harness requires `RUNNER_TEMP` when `TMPDIR` is absent.
- The appliance routing self-test executes a real dashboard payload with system
  `python3`; its import fails because `requests` is absent.

`scripts/test-container.sh` now supplies `RUNNER_TEMP=/tmp` and runs the supplied
command through `uv run --project dashboard --locked`. Its explicit
`UV_PROJECT_ENVIRONMENT` points inside the disposable container, leaving the
host's locked virtualenv untouched. Frozen test files stay unchanged.
A fresh launcher smoke installs 19 locked packages, imports
`requests` 2.34.2 and passes both previously failing self-tests, exit 0.

The full inventory also exposes absent Go and `systemctl` commands. An additive
tools image copies the existing digest-pinned Go toolchain from the appliance
builder and installs real Debian systemd, C build tools and `envsubst`. The original
`tests/runner/Dockerfile` stays unchanged. The launcher keys this layer on the
base image ID, toolchain digest and tools Dockerfile checksum. The final tools
smoke confirms Linux ARM64 Go 1.26.10, systemd 252, gcc 12.2.0 and envsubst 0.21.
It passes the module-watch self-test and all 14 unchanged bridge assertions;
it does not establish a full stack result. Native CLI builds and CI use Go 1.27.1.
The final layer uses separate base/tools tags and a signed Debian snapshot from
2026-11-02, with exact package versions: systemd `252.39-1~deb12u2`, gcc
`4:12.2.0-3`, libc6-dev `2.36-9+deb12u14` and gettext-base `0.21-12`.
Temporary sources isolate these installs from live repositories. Expiry handling
follows [Debian's snapshot instructions](https://snapshot.debian.org/#usage);
signature checks remain enabled. A read-only base-image query verifies all four
candidates before the build.

The known-red initial full attempt is stopped in block 1 after retaining its
log and identity; it has no full verdict. The first fixed full attempt then
exits 2 because Docker's writable filesystem has no free bytes. Its layer is
only 33.5 MB, and the first visible allocation failure creates a six-file
harness sandbox. This is not a completed stack result. The next attempt uses
private host-backed temporary and home directories with the same image,
launcher command and locked dependencies. That attempt exposes corrupted
concurrent append traces on the host bind. A further attempt uses Linux tmpfs
for temporary files and a private dependency home. Cleanup is restricted to
containers created and positively identified by this continuation. The diagnostic
inventory reaches blocks 1 and 2 with six failures: absent Go, systemctl and
envsubst account for four, and the bridge filter accounts for two. It is stopped
in block 3 with exit 143 and no full verdict. Its non-init PID 1 accumulates
orphaned shell children, so the normal launcher now uses Docker's `--init`.
Final full reference and Go runs use separate source and home directories,
the same immutable tools image and Linux tmpfs temporary files.
The final reference attempt ends with container status 137, `OOMKilled=false`,
in block 2 after 4,560 log lines and zero assertion-failure markers. There is no
outer Make exit record. Its cause is undetermined, and this is incomplete evidence,
not a passing run. The raw log and exit inspection remain in private evidence.

The first final Go-selected attempt exposes an adapter defect: replacing
`PITHEAD_GO_REFERENCE` with a tracing trampoline changes the directory used by
status and Bash fallback. Its status and release failures are invalid application
parity evidence. The separate reference run continues. The Go run is stopped
for an adapter repair and must be repeated with the original reference path
preserved.
The invalid run is stopped with exit 143 after 73 assertion failures; its raw
diagnostic log is retained, but its temporary partial trace is lost when the
container stops. The replacement wrapper preserves `PITHEAD_GO_REFERENCE`
exactly and records fallback through the inherited private hybrid marker in
`BASH_ENV`. A native status regression checks both the exact reference path
and the separate install directory's `.env`, with no reference fallback. The
new full Go run copies its trace and report to host-backed evidence before
exiting, so stopping the container cannot discard them.
That second attempt also exposes reference reselection in nested Bash and is
stopped after 63 failures, retaining its partial trace. Persistent private
markers now preserve both actual Go fallback and explicit Bash/Python selection
after the prelude consumes the hybrid marker or the harness scrubs selectors.
The regression covers real prelude consumption, nested Bash, real CLI execution,
ignored signals and exactly one fallback event.
The third run is also invalidated after 63 release-test failures: the adapter's
`source` function supplies the source filename as positional argument 1 when
the original caller passes no explicit source arguments. Its partial trace and
raw log are retained before stopping, exit 143. Source instrumentation must
preserve inherited and explicit arguments, including `set --` behavior, before
the full Go command is repeated. The current repair observes source boundaries
with a DEBUG trap while leaving Bash's source builtin intact. Paired tests cover
zero, inherited and explicit arguments, source return status and sourced `set --`.
The unchanged release-verification fragment now passes 62 assertions with zero
failures. A new full Go run has not started.

## Portable bridge filtering

Two unchanged Caddy assertions fail because the pinned runner's older `mawk`
does not support the `{12}` interval in `container_bridge_addrs`. The fixture
supplies interface output itself; no live Docker bridge discovery is involved.
`lib/pithead/19-small-utilities.sh` now combines an exact 15-character interface
length with the same lowercase hexadecimal suffix check. Other interface
classes retain their original expression. This preserves the intended twelve
hexadecimal characters while working with both awk implementations. The
original reference-path change needs review alongside the runner repair.
The unchanged original bridge fragment passes 14 assertions under the pinned
mawk after this change. The unchanged module-watch self-test also passes with
the real Go toolchain. These focused controls do not replace the full command.

## Additive native evidence

The new `tests/go-parity/stack_native_env.sh` is an opt-in `BASH_ENV` adapter.
It restores Go selection after the unchanged stack library scrubs exported
`PITHEAD_*` variables and initializes selection for standalone scripts. It
preserves the original unexported stack marker. A separate binary wrapper
records fragment visits, helper statuses and standalone reference fallbacks;
the report includes fragments with zero native calls. Event metadata must match
its paired dispatch or sourced visit. Direct scripts have no injected EXIT trap;
their completion is explicitly unobserved in the trace, and asserting a
complete run requires the separately captured outer command status.
Empty traces fail the completeness check. Failed trace writes return status 2;
dispatch and fallback writes must succeed before executing their targets.
Source paths in nested directories and direct fragment paths have explicit
regression coverage. Source visits cover top-level harness fragments; helper
files sourced inside them remain attributed to the owning fragment.

Status 0 is native success, 1 is native rejection and 125 is compatibility
fallback. Other helper failures remain errors. `--require-native NAME` requires
observed native success for the named helper; it does not declare every input
to that helper native. The source-mutation control turns supported keep-running
execution into status 125 and must fail that guard even when Bash succeeds.
The report's `native_errors` also includes nonzero native CLI exits, including
the legitimate status health verdict 1; the original assertions determine
whether those exits are expected. A successful Go entry can still use Bash
providers, as documented for doctor JSON, so counts do not prove an entire
verb's native ownership.

The wrapper waits for the Go child to record its result. Paired closed-stdout
and inherited ignored-signal cases pass. External signal targeting and process
identity remain unproven through this adapter. The passive reference hook
matches the focused original scope fragment's stdout, stderr and status; that
comparison does not substitute for a full original stack verdict.

The twenty-four new adapter tests pass and run in `make test-go-native-guards`.
A sourced visit completes at the next parent DEBUG command; a source used as the
shell's final command stays unfinished and fails strict completeness reporting.
A focused original keep-running run records
132 native successes: 128 env reads and four scope decisions. This is scoped
evidence, not a full stack pass or native lifecycle execution.

## Mixed CI command set before the native-oracle repair

A private Linux ARM64 snapshot of this round runs the Go workflow's command
set with Go 1.27.1. New adapters are staged only in that private snapshot;
the real worktree's Git metadata remains untouched. No dashboard application
module is untracked. The checks pass:

| Check | Result |
|---|---|
| CLI and dashboard builds | Both binaries present, exit 0 |
| Go race tests and vet | Exit 0; 33 race-tested packages |
| Eight focused CLI targets | Exit 0; one unavailable UTF-8 locale and two optional mutant-binary skips |
| Thirty-nine dashboard/shipping targets | Exit 0; shipping comparison 29 passed |
| Final native guard target before DEBUG repair | Exit 0, including the then-current 22 stack adapter tests |
| Reference dashboard and default patch gates | 4102 passed, 95.56% total, 91% changed-line coverage |
| Go dashboard and default patch gates | 4102 passed, 92.60% total, 92% changed-line coverage |

Both default patch runs fetch `origin develop` as CI does and account for all
76 changed files under the measured tree. Existing thresholds and coverage
inclusions remain unchanged. The initial log-copy wrapper mistakes are retained
as failed attempts; the corrected total-plus-patch runs above each exit 0.
Race tests use the compiler-bearing Go image plus the same static jq binary
as the CI tools image. The first bare Go-image race attempt lacks jq and fails
doctor formatting tests; the corrected exact command passes. These checks
establish Linux ARM64 results, not AMD64 execution, a full GitHub job or fleet
approval.
The Go-selected dashboard coverage command is mixed: it leaves many original
HTTP tests on Python. These coverage numbers establish green coverage gates,
not full native ownership. The new strict native-oracle launcher must establish
that separately, with fatal reference bodies and broken-native controls.

A fresh Linux ARM64 snapshot at `778cab2e` plus this round's ten-path adapter
diff repeats both unchanged total and default patch gates successfully: 4102
passed per selection, 95.56% reference and 92.60% Go-selected total coverage,
91% and 92% changed-line coverage, and all 76 measured changed files present.
Build, race, vet and the native guards pass again, including all 24 repaired
stack adapter tests. The application Go and dashboard Python sources are
unchanged. The 39 focused dashboard/shipping targets retain their preceding
snapshot's result; they were not repeated by this run. Later strict-oracle
accounting changes are validated separately. This is still mixed evidence,
with no full pinned stack or childless-backend claim.

The repaired adapter tests are split into hook, report and execution modules
of 214, 181 and 308 lines, preserving all 24 cases. The existing Go dashboard
make include now holds the native-oracle and storage recipes, leaving the root
Makefile at 399 lines. This repairs the file-budget gate without exemptions or
new budget allowances. A synthetic nested-path fixture also uses a temporary
feature name so the repository-path lint does not mistake it for a missing
dashboard source file.

GNU-first full `make lint` passes after these repairs. This gate includes the
unchanged shell, topology and file-budget checks; it does not replace the
remaining full pinned stack runs.
