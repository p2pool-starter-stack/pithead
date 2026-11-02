# RigForge feed parsing parity

Go normalizes the optional RigForge report, including freshness, nullable fields,
watchdog visibility, editable config masking and config provenance. Python keeps
HTTP requests, clock collection, cache timing and the poll/refresh loops.

## Native boundary

The public parser sends the payload and one captured clock to the fleet helper's
`poll_parse_rigforge` operation. Its client, main-poll and post-upgrade/post-apply
refresh aliases all select that native callable in the Go child. An absent or
non-object RigForge block remains null. Nullable and falsy nested blocks default
to empty objects; truthy malformed blocks raise the original `AttributeError`.
The shared channel preserves that exception and the freshness `OverflowError`.

Freshness uses the producer stamp, the original future tolerance, half-even
rounding and the strict stale threshold. Unpadded timestamp components and
lowercase separators retain Python parsing behavior. Explicit integer clocks
convert to binary float before subtraction, including wide integers; values
that overflow that conversion raise. NaN and negative infinity cannot establish
freshness; positive infinity raises during rounding. The original timestamp is
retained only when its age is valid.

Editable config uses the existing native control writable-key predicate. The
same depth-limited traversal now supports both stripping and masking credential
leaves in arbitrary maps and lists. Set credentials become the existing secret
sentinel, while falsy values retain their distinction. Subtrees beyond depth six
become null. Metadata retains only the original normalized revision, timestamp,
source and change ID, including the reference regular expressions' newline and
Unicode-digit behavior.

The main poll uses `poll_merge_rigforge_stats` to parse all reports and run the
existing native merge in one helper process. It does not start a helper for each
worker or transport the result set twice. Python applies returned patches to
the original worker dictionaries after the helper completes. A parser error
leaves the fleet unchanged, preserving the prior Go adapter's publication
boundary. A 1000-worker regression checks one call, worker identity, masking and
unchanged input payloads. For mixed malformed worker inputs, the prior adapter
retains parse-before-merge error precedence; sequential reference partial error
side effects are outside the supported service boundary.

Explicit parser interpositions retain the existing callback path and native
merge operation. This is an intentional callback compatibility case; normal
production selection uses the combined native operation. Unset, Bash and Python
selection retain the reference parser without launching the helper. No native
parser failure calls the Python reference body. Invalid helper reply shapes,
flags, freshness, writable keys and metadata fail closed.

The separate public metadata and credential utilities remain Python for their
other callers. Their equivalents inside this parser are native. The boundary
accepts JSON service values and the existing nonfinite transport; Python-only
object types are outside that service contract. Network requests, discovery,
probe scheduling, cache expiry and refresh waits remain Python.

## Oracle and supplementary evidence

The additive adapter makes the original `parse_rigforge` body fatal, including
both imported service aliases. It records successes, exception kinds and
unexpected reference calls, aggregating counters across xdist workers. A clone
is available only inside explicit paired-reference contexts.

The focused target passes 104 tests: 29 unchanged originals, one existing
parser-interposition comparison and 74 new cases. The originals cover parser,
config filtering/masking, freshness, main poll and refresh behavior, plus five
real-socket fake-worker contracts for normal/miner-down feeds, editor config and
provenance. The same 29 originals pass on the frozen starting checkout and the
current reference.

The 52 new paired comparisons cover nullable/malformed blocks, depth boundaries,
metadata, timestamp formats, threshold/rounding boundaries, nonfinite and wide
clocks, and the combined merge. Seventeen runtime cases cover reply rejection,
exception transport, clock capture, fleet identity, single-call scaling and
failure atomicity. Two source-overlay controls alter the version and credential
masking independently; each breaks an unchanged Python oracle. Three selection
sentinels prove the reference modes never call a fake native executable.

Focused counters record 75 public parser and four combined-merge successes, with
zero unexpected fallbacks. Deliberate malformed inputs produce nine parser
`AttributeError`, three parser `OverflowError` and two combined-merge
`AttributeError` responses. Injected helper replacements and mutation subprocesses
are separate controls. Go units cover the corresponding native policies.

The frozen starting oracle remains
`a73ffced33800de9435779a9cabef53864455acb`. Original tests, fixtures and thresholds
are unchanged; the new comparisons and Go units supplement that oracle.

## Commands and results

```bash
make test-go-dashboard-rigforge-parity
go -C go test -race -count=1 ./...
go -C go vet ./...
go -C go mod verify
```

All four commands pass. Both commands cross-build for Linux amd64 and arm64
with CGO disabled. The bounded CI job includes the focused target.

| Full dashboard run | Assertions | Python coverage and gate |
|---|---|---|
| Current reference | 3719 passed | 81.15%; total gate passes |
| Go selection with storage/native-body adapters | 3832 passed | 78.45%; total gate fails below 80% |
| Separate reference/Go coverage union | No additional assertion run | 96.55%; supplementary combined coverage |

The snapshot contains 3716 frozen original tests and three additions from earlier
rounds. The Go matrix adds 113 native boundary cases without paired reference
comparisons. It records 41 public parser and 142 combined-merge successes, one
expected combined-merge `AttributeError` and zero unexpected fallbacks. Combined
coverage includes retained reference paths; it does not pass the Go-only gate.

| Unchanged patch gate | Native dataset | Reference/Go union |
|---|---|---|
| Default `origin/develop` comparison | 89%; 281 missing of 2569 changed lines; fails | 93%; 164 missing of 2569; passes |
| Frozen starting comparison | 92%; 175 missing of 2228 changed lines; passes | 92%; 160 missing of 2228; passes |

The patch gates now include the committed state-assembly modules. They omit the
new untracked RigForge adapter until the operator commits it; both XML datasets
measure all 34 of its executable statements. Run the patch gates again after
that commit. Existing bases and thresholds are unchanged.

Python/YAML lint, documentation voice and path checks, operator strings,
GNU-first topology checks, file budgets and generated CLI checks pass. The
topology scan includes new files without exemptions. File budgets use the
documented frozen-start override; default-base differences remain in
[PARITY](PARITY.md). Independent correctness and security reviews pass on the
supported service boundary.

Both reference and Go `make test` attempts stop at the unchanged Markdown gate
on third-party files in local dependency caches. Later targets do not run in
those attempts; the dashboard matrices above run separately. The full required
gate remains red. No existing test, check or threshold was weakened.

The dashboard image already copies the complete backend package. Image,
appliance and fleet proof for this working-tree slice remain pending. Checks
use locked Python 3.11, Go 1.27.1, UTC and worktree-local offline caches. Benchmark
files and live stacks are unchanged.
