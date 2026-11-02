# Go selection and shipping integration

The existing launchers and build pipeline now package and select the incremental
Go commands while retaining the Bash CLI and Python dashboard reference.

## Runtime and artifact boundaries

Compose passes `PITHEAD_DASHBOARD_IMPL` into the dashboard container as
`PITHEAD_IMPL`. Its default is Python. Keeping this independent of the CLI selector
prevents an unported CLI verb's Bash fallback from changing dashboard selection.
The entrypoint retains the original Python module command for unset, empty,
`bash` and `python`; `go` execs the configured native executable. Unknown values
and unavailable requested binaries fail startup without automatic fallback.
Both paths retain PID replacement, the existing loopback bind and non-root user.

The dashboard Dockerfile keeps its original default reference target and test
target. `go-production` adds the native executable through the named `pithead-go`
build context. Compose, release images, the appliance's local dashboard build and
CI's runtime-image build select that target. CI still runs the original Docker
test stage and scans the runtime image with its existing Trivy gate. Hadolint now
also checks the new artifact Dockerfile.

The artifact exporter and dashboard builder reuse the appliance's existing
digest-pinned Go 1.26.10 toolchain; the module's minimum remains 1.26. Host and Go
CI checks still use 1.27.1. The artifact exporter builds for the requested target
from its build platform, so Linux AMD64 export on an ARM64 host needs no CPU
emulation. The release bundle remains Linux AMD64, matching the release stack.

Release image construction first archives `go/` from `GIT_COMMIT` into the private
release work directory. Dashboard, rootfs and bundle native builds consume that
same snapshot. The rootfs build receives it as an explicit named context; developer
builds use the working tree. Artifact export uses the configured release Buildx
builder and refuses build failure or either missing executable. Real publication
requires both binaries before bundle checksumming and signing. The one-argument
`make_bundle` reference API stays Docker-free for its unchanged original unit suite;
it is an explicit compatibility path, not proof that production shipped Go.

Bundles and rootfs images retain the generated Bash `pithead` and install native
commands under `go/bin/`. This preserves the CLI's existing executable/reference
lookup. The root primary build context defaults closed and allows only explicit
rootfs inputs; environment files, operational configuration, data, backups, keys
and local caches are excluded. Go source comes through its separate context.

Python remains required by the hybrid Go dashboard. Polling, remaining state
builders, providers, refresh callbacks and business SQL construction remain
Python. No host script or container entrypoint is reimplemented by this slice;
their edits are selection and build wiring. Operator instructions are in
[backend selection](../../dashboard-backends.md).

## Additive proof

`make test-go-shipping-parity` runs 29 new tests; none is an unchanged oracle:

- `test_go_shipping.py` checks all selector modes, exec PID/argv preservation,
  missing/unknown refusal, first-request startup on existing/legacy/corrupt
  databases, native storage ownership, native bundle bytes/layout, missing
  artifacts, the reference bundle API and installed CLI fallback lookup.
- `test_go_shipping_builds.py` checks publication's native-artifact requirement,
  build failure/missing output, immutable archive arguments, configured builder,
  source preparation before image builds, independent dashboard selection, pins
  and the root context allowlist. Provider interpositions are explicit. Removing
  the publication requirement fails its controls; changing Go exec to Python
  must fail the selector assertion.

The entrypoint adapter changes only `/app` to its temporary fixture directory.
The real Go executable then starts its real bridge, with the earlier native
SQLite adapter making original Python connection/schema/recovery paths fatal.
Each startup case sends one state request without retries, checks the miner
contract and terminates gracefully. This is separate from normal image-health
polling below.

`test_go_image.py` adds a Docker-backed CI check using the built runtime image.
Four disposable containers cover Python on an existing database and Go on
existing, legacy and corrupt databases. They have no network or published ports,
a read-only root and temporary data directories. Go cases make Python SQLite
opens fatal through a startup interposition. Checks require healthy state,
miner-response fields/cache policy, migration preservation, quarantine, five
required tables, the correct PID-1 executable and graceful exit zero; sixteen
tables were observed. Health polling is
bounded; it is not a benchmark or additional readiness-probe claim. Three Compose
configurations prove the dashboard choice remains independent of CLI fallback.
Required config values are fixtures; the probe does not read the operator environment file.

## Commands and results

```bash
make test-go-shipping-parity
docker build dashboard
docker build --target test dashboard
docker build --target go-production --build-context pithead-go=go \
  -t pithead-dashboard:wiring-check dashboard
python3 tests/go-parity/test_go_image.py pithead-dashboard:wiring-check
docker buildx build --platform linux/amd64 --file go/Dockerfile \
  --target artifacts --output type=local,dest=.go-cache/shipping-real-native go
```

The plain, test and Go-capable image builds pass. The Docker reference test stage
passes 3709 tests and skips ten, with 83.72% coverage. The four runtime-image cases
pass on Linux ARM64. The Go-capable candidate image ID is
`sha256:bf2aa1c14f344ce06d60ac9a7053aa13c17c623e4be691e3e6e20c1ce2ec8475`.
These are local working-tree builds based on `f62508c52`, not published artifacts.
The immutable archive/provider protocol is checked separately; the new Dockerfile
enters the real release commit only when the operator commits this round.

Actual Buildx artifact export produces both Linux AMD64 ELF executables. Build
metadata reports Go 1.26.10, `CGO_ENABLED=0` and `-trimpath`. An initial host-default
builder attempt lacked write access to its activity directory; a private Buildx
configuration fixes that host constraint. A target-platform builder then required
unavailable CPU emulation; the build-platform cross compiler fixes that issue.
Linux AMD64 execution and a complete appliance build remain unproven here.

The full native dashboard matrix passes all 3737 assertions: 3719 existing
snapshot tests plus eighteen native-boundary cases. Of the snapshot tests, 3716
are frozen original tests and three were added by earlier port rounds. Python
coverage is 79.62% and fails the unchanged 80% gate. Native-only patch coverage
is 87% (272/2196 lines missing) and also fails. Combining the measured reference
dataset with this round's native dataset passes patch coverage at 92% (158/2196
lines missing across 49 tracked files), with 96.47% total Python coverage. This
is paired coverage, not a Go-only gate pass.

No original test or fixture differs from the frozen starting commit. Existing
shell/Python/YAML/topology/generated-CLI/file-budget checks, changed Markdown and
the pinned Hadolint 2.12.0 checks pass without weakening any rule. Go race tests,
vet and module verification also pass. The unchanged redaction selftests pass
39 and 175 assertions with selection unset; the Go-selected source-fetch suite
passes seven tests. Full
`make test` attempts still stop at Markdown lint on third-party local-cache files.
The Go-only Python coverage and patch gates remain explicit failures. Local image
checks do not establish privileged appliance, fleet or release promotion success.
No running stack, registry publication, bench or benchmark worktree is changed.

Pinned Trivy 0.73.0 inspects the candidate ARM64 image's Debian packages, Python
dependencies and Go binary. It reports zero fixable HIGH/CRITICAL vulnerabilities
with the existing CI ignore file and `--ignore-unfixed` policy. The scan identifies
the same candidate image ID above; AMD64 and published-image scans remain pending.

The new `shipping_reference_suites.sh` adapter sources three unchanged release and
appliance fragments through their original harness in the existing Linux ARM64
test-runner image. All 187 assertions pass with `RUNNER_TEMP` configured. The
harness deliberately scrubs both public Go selectors, so this proves the Bash
shipping/reference contracts; it supplies no native CLI execution count. The
first run caught an added operator guide changing the frozen bundle-doc inventory.
The guide is now online, with selection commands also in the existing bundled
dashboard guide; the curated bundle inventory and the oracle remain unchanged.

An extra full Linux `make test-stack` attempt lacked `RUNNER_TEMP`, produced
fixture failures and was stopped (container exit 137). It establishes no full
suite verdict. The disposable test runner mounted Git metadata read-only; no
live stack or shared service was stopped. Original-suite and newly added proof
remain separately labelled. Independent correctness and security reviews clear
the final build and runtime source, including the archive and context changes.
