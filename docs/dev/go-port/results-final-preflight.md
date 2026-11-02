# Final merge preflight

Continuation at pushed head `258de1644b8645819b97748c04f7648822db2594` on
2026-11-02, with new native slices stopped. The actual worktree's application
source and frozen tests remain unchanged. Earlier coverage and CI-command
results remain in the [native CI report](results-native-ci-gates.md).

## Paired frozen stack control

The original `tests/stack/test-tor-network.sh` fragment, lines 695–776, runs with
the complete original `tests/stack/lib.sh` setup and a generated CLI from each
revision. A disposable Linux ARM64 runner supplies real systemd, firewall
permissions and a private dummy interface/default route. It runs as UID 1000
without a host bind mount or Docker socket. The fixture retains its own Docker
stub; no general success replacement is added.

| Source | Passed | Failed | Exit | Seconds |
|---|---|---|---|---|
| Frozen `a73ffced33800de9435779a9cabef53864455acb` | 5 | 3 | 1 | 6 |
| Current `258de1644b8645819b97748c04f7648822db2594` | 5 | 3 | 1 | 4 |

Both logs are byte-identical, SHA-256
`8abcb4268548b569b685cad6e165ce7aedbe0544ee92fedcb5d0a8e08074993a`.
The same three assertions observe an additional network-list call before the
expected Compose call. The fragment and the relevant reference Tor slices are
identical at both revisions. This establishes that narrow failure at the frozen
baseline. It does not replace the failed full reference attempt of 8,050 passes
and nine failures, prove a full Go-selected stack run, or justify editing the
oracle. The runner is stopped and retained.

## Original ext4 replay target

An immutable bundle of `258de1644` runs the unchanged target on Linux ARM64:

```bash
make test-clearnet-replay-proof PROOF_HEAD_SHA=258de1644b8645819b97748c04f7648822db2594
```

The clean source tree is `3c11eb1192fe50066d4f26c7943298be13cb353c`.
Both successful runners use a private ext4 volume, UID 1000, no attached network,
Python 3.11.2 and the ordinary locked uv invocation from Make. Neither sets
`UV_NO_SYNC` nor `UV_OFFLINE`. Dependency preparation uses the same source with
network access before the successful runners start. An initial attempt fails
before pytest because changing ownership invalidates the editable build cache;
preparation under the final UID repairs that prerequisite.

| Selection | Passed | Exit | Pytest seconds |
|---|---|---|---|
| Reference, selector unset | 100 | 0 | 0.89 |
| `PITHEAD_IMPL=go`, built dashboard selected | 100 | 0 | 0.62 |

A shortened source SHA is refused before pytest with Make exit 2. The selected
dashboard was built with Go 1.26.10; the earlier CI-command run used Go 1.27.1.
These timings describe test execution only.

This original test directly invokes the Python clearnet-sync service and loads
no Go parity plugin. The selected binary's presence proves no native ownership.
The result clears the original replay target's runner prerequisite in both
selections; native replay ownership remains unproven.

## Fleet admission and integration base

Both normal API admission attempts name issue #3811, use the required submitter
and an idempotency key, and target pushed `258de1644`. Both return HTTP 422 with
`conflicts_with_base` before creating a job. Idempotency lookups find no job, so
there is no fleet execution, tier result or restoration verdict.

| Requested base | Base SHA | Conflicted paths |
|---|---|---|
| Explicit `develop-v2.1.0` | `b0b0b61a6371e69dd8285ee75b1287be51286d4f` | 3 |
| Default `develop` | `2b8a778fcafa12db40991de95a8563bd5867ca0b` | 30 |

Local branch configuration selects `develop-v2.1.0` as its upstream. Its merge
base with this branch is the frozen `a73ffced` revision. Default `develop` has a
different ancestry and requires a broader semantic reconciliation. Neither
branch is merged into the actual worktree during this continuation; its Git
metadata remains read-only.

A separate private candidate resolves the configured upstream's three textual
conflicts in `Makefile`, `docs/dev/file-budget.tsv` and `os/build-image.sh`.
It retains the Go build and parity checks, the incoming AWK bridge check, and
the Go production-image selection. It restores 109 incoming modifications to
pre-existing test-content paths to the feature head's exact bytes and retains
60 upstream-added test paths. The candidate is uncommitted preparation; its
checks do not establish a merged-branch or fleet pass. The operator must review
the complete candidate, perform the real merge, commit and push before admission
can retry. Standard fleet options provide no per-job Go selector, so even a
later ordinary fleet pass requires execution evidence before claiming Go parity.

## Candidate compatibility checks

The integration base adds `GET` and `POST /api/control/worker-upgrade-all` and
`POST /api/control/power`. All three are absent from frozen `a73ffced` and the
feature head. The private candidate adds their admission to the Go handler's
explicit reference-control route group only when control is enabled. Python
retains authorization, validation and orchestration. Existing native generic
submission and spool publication already accept the resulting requests; no
native action is added. A new Go unit case checks forwarding, disabled 404 and
wrong-method 405 behavior without changing an existing test.

| Candidate check | Result |
|---|---|
| Dashboard, reference selection | 4,163 passed; 95.64% total coverage |
| Dashboard, Go selection after command build | 4,163 passed; 92.73% total coverage |
| Existing default patch command, each selection | 92%; 85 measured files; rehearsal only |
| New upstream control service/HTTP cases with native channel adapter | 40 passed |
| Go HTTP package | Passed |
| Go race units, `-count=1` | Passed; 140 seconds |
| Go vet | Passed; 44 seconds |
| Complete eight-target CLI workflow group | Passed; 526 seconds; conditional macOS skips retained |
| GNU topology and file budgets after merge correction | Passed; 99 seconds |
| Generated CLI, Trivy configuration, protobuf and TOML lint | Passed; separate 110.92-second continuation |

The native-channel run observes fourteen result reads, three submissions and ten
spool writes without compatibility interpositions. An initial Go-selected
dashboard invocation lacks its binary and fails with 273 failures and 179 setup
errors; the required build followed by the exact-final rerun passes. Neither
failure nor rerun is omitted from the private report.

The application checks above run at index tree
`dd8079c48188d8ccbdab5e82ea4cf0e1a2a9bda3`. The final candidate tree is
`342e01893b4013a78e7916cc80b25812cd0bb9b9`; its complete patch has SHA-256
`c545ecd3cb4a76c19086c1601c2c1c8566aead67ae2c5e4d9c9b9d43af11ac71`;
its fallback-only patch has SHA-256
`00c90ece37eb82dc0fbd9aab2f1974a3843733ae0a49a7a6ffd3a208b9119b8f`.
Independent security review passes that compatibility patch, including the
connected Python and host validation paths. It does not audit every upstream
change or exercise live power/fleet operations. The private replay instructions
also preserve this continuation's documentation if the operator commits it
before merging. A changed application source requires renewed preparation.
The broader continuation uses Go 1.27.1 on macOS ARM64 with candidate-local
caches, Python 3.11.15 and uv 0.10.10; CI pins uv 0.12.13. It establishes neither
Linux execution nor a GitHub Actions verdict. The eight CLI workflow targets
pass; their conditional macOS skips do not establish Linux ownership. The full
dashboard/shipping parity groups are not repeated on this candidate.

Broader lint attempts stop first on npm-cache permissions, then uv tool-cache
permissions, then a topology self-test using BSD grep. The corrected GNU run
passes topology but finds a 405-line Makefile, a stale 402-line budget row for
the frozen 400-line stack runner, and files in the worker's unignored npm cache.
The final correction removes five blank Makefile separators, drops that stale
row and moves only the worker's cache into the existing ignored cache tree.
Make dry-run output is byte-identical before and after; no application or test
code changes. GNU topology and file-budget targets then pass. Application tests
are not repeated after this whitespace/metadata correction. These separate
target results do not constitute one successful full candidate lint invocation.
Every lint target now has a passing component result. The generated-CLI,
Trivy-configuration, protobuf and TOML continuation passes at the final tree;
its protobuf target uses the normal two disposable Buf containers. Full CI on
the actual committed merge remains required.

## Actual worktree checks

GNU-first `make lint` exits 0 in 520.58 seconds, including topology, shfmt,
file budgets and the ordinary tool checks. Locked uv dependency invocation
remains enabled. The elapsed time is a local check duration, not performance
evidence. Only ledger documentation changes in the actual worktree; the prior
application coverage, race, vet and focused parity results remain scoped to the
identities in the [native CI report](results-native-ci-gates.md).
The final documentation targets also pass, exit 0 in 232.87 seconds: Markdown,
documentation voice, path references, topology and file budgets. The review
summary remains 22 lines and `STATUS: IN PROGRESS` remains unchanged.
GitHub's Browser regressions push run `41506347147` passes at `258de1644`.
It is the only workflow returned for that pushed head; no Go-workflow or full
CI status is inferred from the browser result.

## Operational incident

During evidence cleanup a delegated worker stopped an unrelated disposable
container running another worktree's dashboard stack test. Docker removed the
container automatically. The interrupted run has no test verdict and its owner
must rerun it. The worker issued no volume deletion or source-file command;
the interrupted test's partial writes and results are unknown. The user was
informed, the worker's mutations stopped, and exact recovery details remain in
the private handoff. No success claim in this report uses that interrupted run.

## Retained evidence

Complete logs and metadata remain ignored, outside published artifacts. The
paired stack files are under `.go-cache/logs/`; the ext4 files are under
`.go-cache/ext4-proof-258de1644/`. Fleet requests, responses and machine contracts
remain in the separate private handoff without copying topology here.

| Evidence | SHA-256 |
|---|---|
| `stack-systemd-a73-onion-paired.meta` | `7f0fd4946c771980704f1cf194c152253e9e2e1872d67fa94c37f32325ad2698` |
| `stack-systemd-258de1-onion-paired.meta` | `7789d0e868845e229a362e5e4a92cc75ce77b0f554e80788c01737ab1ee872fd` |
| `stack-systemd-onion-paired-commands.txt` | `2b46ea3cae1d3a38db500dc4a0e38ee9ff70e91c7501fca9100698db8ed1ea55` |
| Ext4 `reference-pass.log` | `0755438018fe67568abe3dd9643183dda35cbaca90f2db0a8a31831721654353` |
| Ext4 `go-selected-pass.log` | `082a1c7536b92356da3c5cd7c159b39328ad12ae0c2e86bc6340dd8f76190528` |
| Ext4 `bad-sha-refusal.log` | `79997d19287a5d95accf8ca5a78cb553835673b638b091cc2ee24e9e46c64b11` |
| Ext4 `successful-runner-metadata.json` | `f9bf049f3d7865bad72dad3cef90f3cc916be241fc75b30b06e76532aa482e77` |
| Ext4 `clarification.txt` | `1ee820f305bd7bf9d0c497bd9b8e0d17607052be000259bf408a93be6035d93c` |
| Fleet configured-base response | `764af8321db49f191ffed34def422e6ee5b8cdf61b773e2c4f10aac306888090` |
| Fleet default-base response | `5de690b1b88ed0e7c724a820d0f1b6b2ff2c9fbe3d0841ce9743e9270f052b2f` |
| Private incident record | `c38bea5cf2d28b18fe614940322b2f980f2039f497dc6b049356e5be90021d55` |
| `go-merge-final-preflight-lint.log` | `b0734e1108010754302be4e06fb855cfe0b3cd08e8e79a6e1134d0f059d2c09c` |
| `go-merge-final-preflight-lint.json` | `441e80a90f2255ff3624b7cfb915aba6d290b3dd68ab9bf03add54b63c22af4c` |
| `go-merge-final-preflight-docs.log` | `3a9320d2ab8098873ab8a00420a55b1754f567e8c23a97e7c2158d8eed36ff30` |
| `go-merge-final-preflight-docs.json` | `8d23c934d811944ca4cd28dfe43206482f2a35d77873c0105eef836f870abbb1` |
