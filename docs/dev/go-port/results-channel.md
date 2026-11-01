# Wizard views and control protocol parity

This slice ports control intent shaping, UUID handling, worker writable-key
validation, atomic request publication and result-file reads. It also ports
wizard stage/status decisions and read-only spool views. Existing Bash/Python
tests and fixtures remain unchanged; the original suites are distinguished from
new comparison and fault cases below.

## Native scope and launch

`go/internal/dashboard/control/` returns closed generic/worker envelopes, strips
only the existing editor metadata and preserves field order. Python serializes
the resulting ordered pairs with its existing JSON conventions; Go stages those
exact bytes under a private temporary name with mode 0600 subject to the inherited
umask, then renames the inode
onto the request name. It never creates the requests directory. Failed writes
remove their temporary. Result IDs are canonicalized before touching a path;
missing/unreadable files and incomplete JSON retain the pending result contract.
Python still decodes result JSON, preserving arbitrary integers and nonfinite
values, and owns the existing 0.5-second predicate/timeout polling loop.

`go/internal/dashboard/wizard/` reads spool markers and derives installer mode,
stage and status text. Reference, last attempt, rig defaults, data-wipe and saved
role readers retain missing/malformed/nonobject behavior, metadata filtering,
Unicode whitespace and universal-newline handling. Object readers retain large
integers and Python's nonfinite JSON tokens. Raw marker reads retain decoding
errors; object readers fail open on invalid encoded JSON as the reference does.

The Go dashboard command installs `go_control.py` before constructing the app and
fails before app creation if the bridge is missing. The existing wizard command
remains `python -m mining_dashboard.wizard`: its app selects `go_wizard.py` only
when `PITHEAD_IMPL=go`. The server's five-line installation hook stays within its
unchanged 671-line ceiling. Unset, `bash` and `python` do not invoke native helpers,
even when a helper override is present. No production container switch is added.

`go_channel.py` uses a bounded subprocess call with no reference fallback.
Per-call collision-checked markers preserve nonfinite values across the strict
helper envelope. Native helper failure is fatal. Status and authenticated state
requests each share one in-flight task per app; collection runs off the aiohttp
event loop and state holds the existing submission lock. Completed responses are
not cached. State waiters receive separate response objects. Cleanup joins any
pending bounded task.

Wizard auth, TLS/binding, config/form shaping, install/node validation, submission
transactions, restore upload/cleanup and handoff writes remain Python. Dashboard
control route guards, config masking, audit/diagnostic/backup presentation and
HTTP response orchestration also remain Python behind the Go route table. This
is a hybrid backend, not a complete native wizard or control server.

## Adapters and native proof

New files under `tests/go-parity/` supply the smallest hooks used by this slice:

- `dashboard_channel_plugin.py` installs native functions before collection and
  makes the original ported function bodies fatal, including captured aliases.
  It records successful native operations and explicit mock interpositions.
- The original request-spool tests patch Python `os.replace` to observe the
  atomic inode or inject publication faults. In those three cases the adapter
  uses native staging and the injected Python rename; normal production writes
  execute the complete native stage/rename path. The original pinned-UUID route
  test injects its UUID before native normalization/shaping. These four hooks
  are intentional compatibility cases, not native rename/randomness proof.
- `dashboard_channel_compare.py` adds exact request-byte comparisons against a
  separate reference process, all result JSON shapes, helper failures, large
  integers/nonfinite values, read errors, selector sentinels and concurrent
  status/state checks. Twelve waiting requests share collection while auth
  remains responsive; subsequent spool changes appear immediately.
- `dashboard_channel_startup.py` exercises the normal Go command through its
  Python child and control HTTP routes, with original control functions fatal.
  It also proves a missing native bridge aborts before app creation.
- `dashboard_channel_guards.py` compiles isolated source overlays that break
  native submit or wizard stage. Each mutation makes the unchanged original
  oracle fail; the working tree is never mutated for those controls.

Native Go units additionally check UUID forms, field/metadata order, writable
keys, read errors, stream framing, atomic inode permissions/publication,
failure cleanup and wizard marker precedence/JSON behavior. The existing module
pin for `github.com/google/uuid` 1.6.0 becomes a direct dependency; no version or
checksum changes.

## Commands and results

Commands use the worktree-local Go/uv caches documented in PARITY.md, Python
3.11 from the locked dashboard environment and no Docker/live stack.

The focused original command is:

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest \
  tests/service/test_control_service.py tests/service/test_control_result_polling.py \
  tests/service/test_request_spool.py tests/web/test_server_control_routes_enabled.py \
  tests/web/test_server_control_routes_disabled.py tests/web/test_wizard*.py
```

`make test-go-dashboard-channel-parity` runs those same files unchanged with
`PITHEAD_IMPL=go` and the channel plugin, then adds the new comparison/startup/
mutation cases. The bounded Go CI job includes this additive target.

| Check | Reference result | Go result |
|---|---|---|
| Focused original suites | 377 passed at the frozen starting SHA and current head | 377 passed unchanged with `-p dashboard_channel_plugin` and the same paths |
| Additive channel target | New comparisons run their reference arms separately | `make test-go-dashboard-channel-parity`: 403 passed: 377 original plus 26 new cases |
| Full dashboard | `PITHEAD_IMPL=python make test-dashboard`: 3719 passed, 92.83% Python coverage | Full Go command below: 3719 passed, 84.75% Python coverage |
| Go units and static checks | Reference oracle retained | `go -C go test -race -count=1 ./...`, `go -C go vet ./...`, `go -C go mod verify`: passed; final control race check also passed |
| Builds | Bash/Python retained | `make go-build go-dashboard-build`, CGO-disabled Linux amd64/arm64 command builds: passed |
| Patch coverage | Reference-only `make test-patch-coverage`: failed at 66% | Go-only failed at 83%; appended comparison run passed at 94% over 34 changed measured files |
| Full Make gate | `PITHEAD_IMPL=bash make test`: exit 2 at third-party cache Markdown | Same Go adapter environment below with `PITHEAD_IMPL=go make test`: same exit 2 |

The frozen focused command used an isolated `git archive` of
`a73ffced33800de9435779a9cabef53864455acb`, the same test paths above and the
installed Python 3.11 environment. It ran against the archived Python package.
The 3719 full-suite count includes all 3716 original tests and three snapshot
tests added in an earlier port slice.

The full Go command was:

```bash
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_channel_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

The separate original-only Go run recorded 24 native submissions, 21 complete
native writes, six worker validations, 74 stage and 16 status calls, and 826 raw
wizard reads. Other object readers and result polls also executed natively.
Result-poll counts vary with scheduling. The three rename interpositions and
one injected UUID were reported separately. No native-call count is inferred
from the parent process of an xdist full-suite run.

Coverage comparisons were appended with:

```bash
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
make test-go-dashboard-overview-parity test-go-dashboard-fleet-parity \
  test-go-dashboard-http-parity test-go-dashboard-storage-parity \
  test-go-dashboard-channel-parity
make test-patch-coverage
```

Those targets passed 202, 151, 34, 357 and 403 tests respectively. Reference-only
patch coverage was checked from a fresh XML report generated from its separate
coverage data, then the appended report was restored. The unchanged gate does
not include new untracked files until the operator commits them. The appended
XML separately measures the new bridges at 57/59, 31/31 and 81/82 executable
lines (`go_channel.py`, `go_control.py`, `go_wizard.py`), 169/172 combined.

GNU-first topology, generated CLI, file-budget, docs voice, path references,
operator-string and YAML checks pass. File budget uses the documented starting
SHA override; no ceiling changes. Topology also passes with additive enumeration
of the new untracked files, using the original scanner and allowlists. Full Ruff
lint/format, changed-document Markdown lint and `git diff --check` pass. The
reference clean-checkout CLI selftest passes with the optional Go Make include;
the explicit new parity target still fails if its addon is absent.

Both full Make runs pass shell lint and stop at third-party Markdown in the
required local uv cache. No original check, test, fixture or lint rule changed.
Independent correctness and security reviews found no remaining defect after
the wizard off-loop/coalescing fix. A final paired umask comparison covers 0,
0077 and 0777: native publication retains the reference's restrictive modes.

## Limits and next

Python remains required for the hybrid backend and the wizard launch. Native
read helpers currently start per call; no performance gain or image-memory-cap
proof is claimed. Performance measurements have a separate owner. The original
Linux-only stack harness still scrubs Go selection for sourced assertions; these
dashboard checks do not change or prove that harness.

Finish wizard mutations/control orchestration, then add the production selection
switch and shipping artifacts. Docker/image, appliance, privileged Linux and
fleet proofs remain pending on a pushed build with selection support.
