# Host configuration audit parity

Go computes changed configuration key paths and excludes changes explained by
recent dashboard commits. Python retains the masked-file reader, commit-log
reader, timestamp parser, env-name provider, async watcher and audit writes.
Worker/control-history reconciliation and control-log mirroring remain Python.

## Native boundary

Two operations use the existing ordered typed configuration protocol:
`audit-diff` compares the old and current documents, and `audit-unexplained`
filters the resulting changed paths against explained paths. The protocol retains
Unicode strings, lone surrogates, number types and NaN identities. Production
inputs come from the existing reader's defense-in-depth secret masking. Masked
values travel over private stdin for equality comparison; responses contain only
key names. This slice adds no file, network, database or clock access in Go.

Diffing retains nested-dictionary flattening, opaque secret sentinels, empty
objects, added/removed leaves, Python numeric equality and insertion-order
collisions between literal dotted keys and nested keys. Sentinels use the same
dictionary equality as Python, including Boolean/numeric equality. Changed paths
are sorted, with every root `config_version` path excluded. The exclusion phase
preserves input order and duplicates; a path is explained only by an equal path
or a prefix followed by a dot.

Python validates string lists, sorted unique diff paths and the version exclusion.
A returned unexplained list must be an ordered subsequence of the changed paths.
Malformed replies and helper failures raise without reference fallback. The
normal service boundary consists of JSON documents and string path collections;
arbitrary Python-only keys, opaque leaf objects and iterator side effects remain
outside that boundary.

The shared watcher retains its original provider and callback order. Disabled
control, an unavailable file and the first baseline read remain quiet. It takes
one clock reading after the file read, preserves the one-second grace window,
and invokes timestamp/env-name providers only for qualifying log entries. The
current snapshot and clock become the next baseline only after a required audit
write completes. A failed write or native policy call leaves the prior baseline
available for retry. Forced interleaving cases retain the original snapshot
identity and mutations visible across callbacks.

## Oracle and supplementary evidence

The additive adapter makes the original diff body and the extracted reference
exclusion body fatal under Go selection. Both imported diff aliases are selected
together. Paired contexts alone expose reference clones, and native completions,
errors and unexpected reference calls are counted across xdist workers.

The focused target passes 121 tests: 79 unchanged originals and 42 additive cases.
Originals cover data helpers, host-config detection and version-stamp exclusion.
The same 79 originals pass against the current reference and frozen starting
checkout, `a73ffced33800de9435779a9cabef53864455acb`. Existing tests, fixtures and
thresholds remain unchanged.

The additions compare nested and sparse documents, secret sentinels, dotted-key
collisions, number equality, NaN identities, surrogate paths and exact prefix
matching. Runtime cases preserve callback order, timestamp eligibility, the
one-second boundary and failed-write baseline retention. Invalid replies and
transport failures cannot use the reference policy. A source mutation disables
changed-value detection and fails an unchanged host-watch test. Separate controls
prove xdist counter aggregation and that unset, Bash and Python selection never
invoke native helpers.

Focused counters record 40 diff and 18 unexplained completions, one deliberately
invalid non-string-path `TypeError`, and zero unexpected reference calls. Mutation,
worker-process and selector subprocesses are separate controls. Go units include
20000-key scaling and input-immutability checks.

## Commands and results

```bash
make test-go-dashboard-host-audit-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both commands cross-build for Linux amd64 and arm64 with
CGO disabled. The focused target is included in the bounded Go CI workflow.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 79.82%; total gate fails below 80% |
| Go selection with storage/native-body adapters | 3891 passed | 78.09%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.40%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three earlier additions.
The Go matrix adds 172 native boundary cases without paired reference comparisons.
Worker-aggregated host-audit counters record 23 diff and 11 unexplained completions,
one deliberate non-string-path error and zero unexpected reference calls.
Reference coverage declines from 79.9983% to 79.82% because the reference run does
not execute the new native adapter. Combined coverage retains both modes; it does
not pass the Go-only total gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 88%; 340 missing of 2876 changed lines; fails | 93%; 191 missing of 2876; passes |
| Frozen starting comparison | 90%; 234 missing of 2535 changed lines; passes | 92%; 187 missing of 2535; passes |

These patch gates include the committed telemetry module and this round's tracked
production Python changes. Bases and thresholds remain unchanged.

Python/YAML lint, scoped Markdown checks, documentation voice and path checks,
operator strings, GNU-first topology checks, file budgets and generated CLI
checks pass. Topology includes new files without exemptions. File budgets use the
documented frozen-start override; default-base differences remain in
[PARITY](PARITY.md). Independent correctness and security reviews pass. The added
reply checks cover decoding failures, duplicate/unsorted/version diff paths and
injected/reordered unexplained paths.

Both final reference and Go `make test` attempts stop at the unchanged Markdown
gate on third-party files in local dependency caches. Later targets do not run in
those attempts; the dashboard matrices above run separately. An earlier reference
attempt encountered a test file while formatting was in progress; the final
attempt supersedes that transient lint result. The full required gate remains red.
No existing test, check or threshold was weakened.

The dashboard image copies the complete backend package. Image, appliance and
fleet proof for this working-tree slice remain pending. Checks use locked Python
3.11, Go 1.27.1, UTC and worktree-local offline caches. No benchmark file, live
stack, existing check or threshold changed.
