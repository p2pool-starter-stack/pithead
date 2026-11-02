# Native coverage CI continuation

This continuation starts from committed head
`717ae23b190d74e17dc20f4f18d1c970d2b80803` on 2026-11-02. It adds no native
slice or application change. Original tests, fixtures, coverage thresholds and
coverage module selection remain unchanged.

## Coverage at the committed head

The ordinary Make targets run separately for each implementation selection with
GNU tools first on `PATH` and the locked Python 3.11 environment:

```bash
env -u PITHEAD_IMPL make test-dashboard
env -u PITHEAD_IMPL make test-patch-coverage
PITHEAD_IMPL=go make test-dashboard
PITHEAD_IMPL=go make test-patch-coverage
```

`COMPARE`, `GITHUB_BASE_REF`, `COVERAGE_FILE`, `PYTEST_ADDOPTS` and `PYTHONPATH`
are unset. Each patch gate reads the immediately preceding dataset and uses the
default `origin/develop` comparison. No coverage union is used. There are no
untracked application modules under `dashboard/mining_dashboard`.

| Selection | Passed tests | Total coverage | Default patch coverage |
|---|---|---|---|
| Reference, selector unset | 4102 | 95.56% | 91% |
| Go | 4102 | 92.60% | 92% |

Both datasets measure 13,044 statements. The reference dataset misses 579 and
the Go dataset misses 965. Each patch report measures 4,106 changed lines across
76 changed application files; reference misses 341 lines and Go misses 318.
All 76 files appear in their respective fresh `coverage.xml`. All four commands
exit 0; the total and patch thresholds stay at 80% and 90%.

## Required native coverage step

The existing bounded Go workflow gains a step after its command builds:

```bash
make test-dashboard
git fetch --no-tags origin develop "${GITHUB_BASE_REF:-develop}"
make test-patch-coverage
```

The step sets `PITHEAD_IMPL=go`. It uses the same base-fetch and default patch
selection as the existing dashboard job, including a pull request's own base.
The reference dashboard job and every existing Go check remain intact. The Go
workflow timeout stays at 25 minutes. Before this change, the Go-selected total
and patch coverage figures were local evidence rather than workflow gates.

GNU-first `make lint` exits 0 in 177.44 seconds, including shfmt, topology and
file budgets. Independent review finds the step preserves the existing base,
permissions, prerequisites and checks.

## Updated Go workflow execution

An isolated Linux ARM64 clone runs every command in the updated workflow as UID
1000, using Go 1.27.1, Python 3.11.2, uv 0.12.13 and GNU Make 4.3. Its head is
`717ae23b190d74e17dc20f4f18d1c970d2b80803`; the only working-tree change is
the workflow overlay with SHA-256
`1b7e2133c1a3cb74cd5ce8fe9b9810b3c8cc48f8635e4b4f005ddbcc12b3944a`.
The source is copied from an immutable Git bundle, without a host bind mount.

| Phase | Exit | Seconds |
|---|---|---|
| Both command builds | 0 | 6 |
| Go dashboard coverage, real base fetch and default patch gate | 0 | 175 |
| Race units | 0 | 17 |
| Vet | 0 | 2 |
| All eight CLI parity targets | 0 | 136 |
| All 39 dashboard parity targets and the shipping target | 0 | 317 |

All command phases exit 0 in 653 seconds (10m53s), excluding runner preparation.
The coverage step passes 4,102 tests at 92.60%, performs the real read-only
`git fetch --no-tags origin develop develop`, and passes the default
`origin/develop` patch gate at 92%. `COMPARE` stays unset. All 76 changed
application files appear in the fresh coverage report, with no untracked
application modules.

The CLI step retains three explicit conditional skips: the non-UTF-8/Latin-1
status case lacks its locale, and two keep-running controls lack their optional
mutant binaries. The native-ownership guard group passes all eighteen cases
without skips. The forty focused dashboard/shipping invocations report 8,489
passing test executions and no skips; these overlapping invocations are not a
unique-test count. This is local ARM64 execution of CI's commands, not a GitHub
Actions status, AMD64 execution or fleet result.

## Dashboard Docker test stage

An immutable archive of the committed dashboard context runs CI's existing
Docker test target with no implementation selection:

```bash
docker build --target test -t pithead-dashboard:test-717ae23b1 dashboard
```

The build exits 0 on Linux ARM64: 4,092 tests pass, ten skip in the dashboard-only
context, and total coverage is 95.56%. The image ID is
`sha256:9af6fe26207fea7290a77f192644ef07bb33e4a232fca9a7e5f326635da7ed20`.
The test stage retains the bridge modules and the unchanged 80% gate. The
ordinary repository runs above retain all 4,102 passing cases.

## Full Linux stack attempt

A separate disposable Linux ARM64 runner supplies real systemd as PID 1,
private cgroups, working firewall permissions and passwordless sudo. The source
is an immutable bundle at `717ae23b`; the suite runs as UID 1000. The runner has
its own network namespace, no host mounts and no Docker socket. Global success
fakes are not used.

The unchanged reference `make test-stack` completes its five main shell blocks
with 8,050 passing and nine failing assertions, then exits 2 after 1,084 seconds.
It does not reach the Make target's remaining standalone commands. This is a
failed gate, not a full Linux or Go-selected pass.

| Main block | Passed | Failed |
|---|---|---|
| 1 | 2511 | 0 |
| 2 | 1899 | 3 |
| 3 | 323 | 6 |
| 4 | 277 | 0 |
| 5 | 3040 | 0 |

The original pull-policy fragment separately passes all thirteen assertions with
real systemd and firewall operations, correcting the older runner's missing
prerequisites. Block three's six failures follow an unavailable route: its
unchanged control-channel fixture uses a UDP socket to discover the local
listener address. A real private dummy interface and default route inside the
isolated namespace satisfy that prerequisite. The unchanged reference block
then passes all 329 assertions in 195 seconds, exit 0. This follow-up does not
replace the failed full attempt or establish a Go-selected block result.

Block two's three failures observe an extra Docker network-list call in the
node-onion fixture. The relevant call and expectations exist at the frozen
starting commit as well. The frozen `a73ffced` runtime control stops at the
agreed time limit with exit 130 before reaching those three assertions. Their
runtime non-regression remains unproven; static identity is not a passing
baseline control. An earlier extracted-fragment attempt times out after 45
seconds with exit 124 after two preliminary assertions; it also does not reach
the three target assertions.

The selected compiler and built CLI identify Go 1.27.1, and the CLI's VCS revision
matches the clean UID-1000 checkout. The privileged runner is stopped and
preserved for inspection. No original test, fixture or reference implementation
is edited to hide these results. Full Go-selected stack, privileged host
behavior and the Linux ext4 replay gate remain unproven.

## AMD64 runner boundary

An additional attempt builds the existing `go-production` target with
`--platform linux/amd64` and its named Go context. The build exits 1 when the
builder cannot execute the target shell (`exec format error`, build-step exit
255). No AMD64 runtime image or execution pass is claimed. The earlier AMD64
artifact export remains compilation proof only. No emulator registration or
host configuration is changed to bypass this runner limit.

## Private evidence

Complete logs stay under the ignored `.go-cache/logs/` directory. They are not
published artifacts.

| Evidence file | SHA-256 |
|---|---|
| `committed-717ae23-baseline-dashboard.log` | `d029e80c4fd8dc7b8bca2d69d666fb580c5ce6436d2236a75abf9e54d7e0e838` |
| `committed-717ae23-baseline-patch.log` | `15e3b246ce90b6574414ca2bb12d5793f02bfa1d062b1d0e90f5edfded5c14bc` |
| `committed-717ae23-go-dashboard.log` | `8674b7260ebf7972316c8257a0e3d8e237637da5ce155a1ba19a75996521dbd5` |
| `committed-717ae23-go-patch.log` | `0074803a184c33992548600281c05d5b1e95d9a7d0e76e5bedcff7a1dbdfe75f` |
| `dashboard-test-stage-717.log` | `4c53c0e33eeda3d2ee1251380635c282ca17cd239dba343eba0c88e2779168ab` |
| `go-merge-native-ci-coverage-lint.log` | `4b862f03bfd5f162b4d05cf4cbfc28f07ea376997557130c86a057ce1756a720` |
| `go-merge-native-ci-coverage-lint.json` | `35f705cd2c26ee4fd768f54d9dcede3088b923f9234a1bd4dd0bc6c593d2694c` |
| `dashboard-amd64-build-717.log` | `cdb639baf63f2105be05cbd20d1e147935c8ef55738c64c72341623787b2ecd1` |
| `stack-systemd-717-reference.log` | `c0ada3d62b147f4925fb8007b146aa33368768cedd428940bea1a91a111ebc26` |
| `stack-systemd-717-reference.meta` | `60187470965506639044202161dbe4d5c4657190c1b533ed4ad58413e0109a25` |
| `stack-systemd-717-pull-policy.log` | `2875bb7559b0469c580363740cc6e96ad52f81f518df54afe9918e99de6c8dcd` |
| `stack-systemd-717-pull-policy.meta` | `5412388f8f8bdaf4f769a7bc4e4ad49ab53bf6b26fd007e1075862cb0c50542d` |
| `stack-systemd-717-reference-block3-dummy.log` | `3378a08e9705454a14ad9466351405864500672963ce4cdfceedd19ac4aadfe7` |
| `stack-systemd-717-reference-block3-dummy.meta` | `a6af42010437af58e8ef84be0065051b14617b011e595fa3cb7e8c06caa94f76` |
| `stack-systemd-a73-reference-onion-fragment.log` | `e40068b029e14cab9804b34ed2d27814a3bfbfd2339ad9380b601c50b6d4fc4e` |
| `stack-systemd-a73-reference-onion-fragment.meta` | `f027941162a74c69ecf5bf18e1fcbdc61c33047231edb118714772b16f2a4577` |
| `stack-systemd-a73-reference-tor-network.log` | `25f2607e8f9df1bad9324aed72ab63183493e0d3f3cba337a4f0adc79b31580e` |
| `stack-systemd-a73-reference-tor-network.meta` | `3a1ac52623b86cb3f2e969c91e51a732c48f938dee80986fab0c48f6101762a7` |

The updated Go job retains its separate `.go-cache/go-ci-final-717-logs/`
directory:

| Evidence file | SHA-256 |
|---|---|
| `build.log` | `23f7b9217cd4648eb54b888c9511a81178886dd7d89a6e83677534e07b53b1d1` |
| `coverage.log` | `16c923be4ac21fc8b62864d7017920cb043907141adb7d3ffae29088a6cc4333` |
| `race.log` | `408ec629de771aed44cac27ae3cedb052cdddbae2c0c7a4feeb8866d53f6d774` |
| `vet.log` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `cli.log` | `d036be951492bfb3834a45a6d0b9c13349db69739f135a28818417d80cadff48` |
| `dashboard.log` | `f6944ee2dd2d87410deef91f768099a592e088016a726af53552a524531eca30` |
| `phase-status.tsv` | `ead51d25f5ab42a8471ecdf05ac4fbddce5e1d749a11c03e24ec4b6548789c88` |
| `run-go-ci-final.sh` | `dbef301406855920a1243360504b0963ce5c9a22b4135ba5d30cfe976f9dd2da` |
