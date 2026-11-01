# Wizard auth and form policy parity

Go now owns the wizard's token canonicalization, cookie comparison, login
failure/lockout decisions, form configuration plan and install-request validation.
The original Python implementations remain the reference. Existing tests and
fixtures are unchanged.

## Native boundary

`go/internal/dashboard/wizard/auth.go` implements the token policy with constant-time
ASCII comparison. Empty tokens short-circuit; non-ASCII comparisons retain
Python's `TypeError`. Canonicalization strips the same whitespace, applies
Python 3.11 Unicode uppercase and removes one `PIT-` prefix. The small case table
includes expansions and overrides for Unicode version differences; a full-range
scalar-value digest checks it against the locked Python interpreter's mappings.
Success preserves the failure count. Failure increments it and selects 403 or
429 at the supplied threshold.

`form.go` chooses defaults, branch conditions, ports, optional services, role
overrides and clearnet-sync flags. It emits mutations in the reference's order,
including ordered replacement objects. Python applies those generic mutations
to its runtime default shape and retains its existing JSON serializer. New
stratum passwords always use 12 bytes from Go's cryptographic random source;
there is no entropy override in production or the helper protocol.

Install validation preserves disk-list membership, exact confirmation, wipe-mode
validation and the rule that a fresh disk normalizes destructive modes to `keep`.
Duplicate disk names retain the final descriptor, as the Python dictionary does.
Missing inventory keys retain `KeyError`; validation errors retain `ValueError`.

`go_wizard_policy.py` installs all five native wrappers on the server and the
original form/install modules before route construction. Reference modes do not
install it. Native helper failures are fatal, with no Python policy fallback.
All token/password/config data crosses stdin, never argv or diagnostic counters.

Python still owns aiohttp response/cookie serialization, the application failure
counter, response flush before exit code 3, and the existing launch command.
Input `str`, whitespace/lowercase, truth and digit/integer normalization plus
the shared runtime defaults table remain Python bridge inputs. Go decides which
inputs are used, including deferred errors for inactive remote-port fields.
Config/document parsing and migration, machine-name validation, upload policy,
node probes, recovery and submission/handoff orchestration remain Python.
Container selection and shipping artifacts are not added by this slice.

## Adapters and native proof

Only new files under `tests/go-parity/` supply harness hooks:

- `dashboard_wizard_policy_plugin.py` layers over the transaction/channel plugins,
  installs the native policy and makes every captured original policy body fatal.
  It records native success and error classes without input values.
- `dashboard_wizard_policy_compare.py` runs separate Python and Go processes for
  Unicode canonicalization, cookie errors, HTTP lockout and cookie attributes,
  exact serialized config ordering on both platforms, port/default/optional
  branches, password shape and install validation success/error cases. Generated
  password content alone is normalized in the new comparison; original tests
  remain unchanged and Go units check independent random values.
- `dashboard_wizard_policy_guards.py` builds isolated source overlays. Forced
  login acceptance fails the unchanged wrong-token oracle; an empty form plan
  fails the unchanged remote-node credential oracle. Each control requires the
  original assertion failure and a successful native-helper counter.

The additive target runs all original wizard files and the original shared
configuration-defaults file. Earlier port-added channel/transaction targets now
load the new plugin so their original fault tests also execute the native policy.
Their syscall/UUID interpositions remain separately listed in earlier reports.
No pre-port target, test, fixture, lint rule or threshold changed.

## Commands and results

Commands use the worktree-local Go/uv caches from PARITY.md and the locked
Python 3.11 environment. No Docker, live stack or fleet job was used.

```bash
cd dashboard
PITHEAD_IMPL=python .venv/bin/python -m pytest \
  tests/web/test_wizard*.py tests/web/test_config_defaults.py
```

That command passes 322 original tests in the current reference and in an
isolated archive of `a73ffced33800de9435779a9cabef53864455acb`, using the same
installed interpreter with the archived package. The six new cases are
supplementary comparisons and mutation controls, not unchanged suites.

| Check | Reference | Go selection |
|---|---|---|
| Focused original files | 322 passed at the frozen start and current head | 322 passed unchanged with all captured policy bodies fatal |
| Additive policy target | Four comparisons run separate reference processes | `make test-go-dashboard-wizard-policy-parity`: 328 passed, including two mutation controls |
| Earlier port-added targets | Reference oracle retained | Channel: 403 passed; transaction: 295 passed through the policy adapter |
| Go checks | Python reference retained | Full race units, vet, module verification and CGO-free Linux amd64/arm64 command builds passed |
| Full dashboard | `PITHEAD_IMPL=python make test-dashboard`: 3719 passed, 91.69% Python coverage | Full Go command below: 3719 passed, 83.59% Python coverage |
| Patch coverage | Reference-only gate failed at 53% | Go-only gate failed at 84%; appended comparisons passed at 94% |

The focused original paths plus the new cases recorded 207 native login
decisions, 310 cookie checks, 68 form plans and 20 successful install validations.
Error classes are counted separately; invalid install requests also execute Go.
The original transaction fault tests retain their explicit I/O callbacks.

```bash
make test-go-dashboard-wizard-policy-parity
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin,dashboard_wizard_policy_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard
```

The full dashboard count includes the 3716 original tests and three snapshot
tests added by an earlier slice. Native counters in xdist workers are not
inferred from the parent process. Performance evidence has a separate owner.

The native commands were:

```bash
make go-build go-dashboard-build
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C go build -o "../.go-cache/wizard-policy-linux-$arch/" ./cmd/pithead ./cmd/dashboard
done
```

Coverage comparisons are appended with:

```bash
PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
make test-go-dashboard-overview-parity test-go-dashboard-fleet-parity \
  test-go-dashboard-http-parity test-go-dashboard-storage-parity \
  test-go-dashboard-channel-parity test-go-dashboard-wizard-transaction-parity \
  test-go-dashboard-wizard-policy-parity
make test-patch-coverage
```

Fresh reference and Go XML reports are retained and graded separately before
appending. The unchanged gate measures tracked changes; newly added files enter
its diff after the operator commits. The new bridge's executable-line coverage
is also checked directly in the appended XML.
The seven targets pass 202, 151, 34, 357, 403, 295 and 328 tests respectively.
The final gate measures 38 changed tracked Python files and passes at 94%.
The new policy bridge is measured at 64/67 executable lines; shared channel and
wizard bridges measure 59/61 and 85/86. Untracked-file coverage is stated
separately from the tracked diff gate.

Both full Make attempts use `make test`, once with `PITHEAD_IMPL=bash` and once
with the Go plugin environment above. They pass shell lint and stop at Markdown
in the required local dependency cache. No original check was weakened to
bypass it. Independent correctness and security reviews found no remaining
issue in this slice. Linux-only CLI, Docker/image, appliance, privileged and
fleet proofs remain unavailable or unrun locally; no live stack was touched.
GNU-first topology, file budget with the starting-SHA override, generated CLI,
full Ruff lint/format, docs voice/path references, operator strings, YAML,
changed-document Markdown and diff checks pass. The original topology scanner
also passes with additive enumeration of the new untracked files. No existing
test file differs from the frozen starting commit. No budget ceiling changed.

## Remaining work

Finish wizard config/submission/recovery/handoff and remaining control
orchestration, then add production selection and release/dashboard/appliance
shipping integration. Polling, business SQL and remaining state handlers still
make this a hybrid backend.
