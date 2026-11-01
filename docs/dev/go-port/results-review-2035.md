# Operator 20:35Z review results

This slice addresses the six findings from the operator's independent review of
`32d18559`. The starting-source comparison is
`a73ffced33800de9435779a9cabef53864455acb`. Earlier reports' reference arms used
the then-current snapshot; they did not establish that the Bash reference itself
was unchanged from this starting source.

## Reference gates

The Go publication fallback in `33-render-env.sh` now uses a cat here-string. The first
heredoc is the original `.env` key list, so the existing redaction guards discover
the full population again. Both original selftests pass with `PITHEAD_IMPL` unset,
with identical results at the starting commit and repaired head:

| Unchanged check | Frozen starting source | Repaired head |
|---|---|---|
| `bash tests/integration/selftest/selftest-redact-vocab.sh` | 39 passed, 0 failed | 39 passed, 0 failed |
| `bash tests/integration/selftest/selftest-bundle-redact-env.sh` | 175 passed, 0 failed | 175 passed, 0 failed |
| `python3 tests/stack/lib/config-document-parser.py` | 7 passed | 7 passed in reference mode; Go ownership guards also pass |
| GNU-first `make lint-topology` | Passed | Passed |

The proposed `printf` form broke existing cat-interposition comparisons. The
here-string preserves that behavior and the original heredoc's trailing newline
without introducing a second heredoc for the redaction scanners to mistake for
the schema. GNU tools are required for topology lint; the native env writer's
standard-tool ownership assertions run with their normal PATH.

`run_env_write_parity.py` is a new adapter over eleven pre-existing supplementary
env-writer comparison methods. It reuses the existing private-marker adapter for the one
legacy internal-fallback case; explicit public Bash selection still ignores
native helper overrides. The target now uses that adapter, so its native-success
assertions run without restoring the earlier selector leak. Direct legacy-marker
execution and GNU's nonstandard cat path intentionally require these compatibility
distinctions; neither is counted as a native success.

Topology repairs remove 111 findings across 23 port-added test files. Ordinary
synthetic addresses use documentation prefixes, allowed private-range fixtures
and example domains. Essential classifier boundary cases construct their RFC1918
inputs with `net.IPv4` or numeric formatting, preserving the tested classes.
There are no new exemptions, scanner changes or edits to pre-port tests.

GNU tool directories precede the inherited PATH for these checks:

```bash
export PATH="$(brew --prefix grep)/libexec/gnubin:$(brew --prefix coreutils)/libexec/gnubin:$(brew --prefix gnu-sed)/libexec/gnubin:$PATH"
```

BSD grep's scanner selftest failure was not evidence that the repository scan was
green. The earlier host-only topology verdict is superseded by these GNU results.

## Bounded state transport

The production state and metrics collectors now compute five exact history
averages in Python. State collection uses its captured snapshot clock and filters
and downsamples chart rows before JSON serialization. Go retains those bounded
rows locally while POSTing only the metrics, sections and frozen snapshot to the
Python assembler; the POST response also omits history. Go projects the prepared
chart rows and builds gaps, share/event/raffle/payout markers and tension.

The standalone Go average and full-chart implementations remain exercised by the
existing adapters. Production range filtering, downsampling and the five averages
are currently Python-owned. Legacy direct fixtures retain their earlier input
protocol; they do not prove compact production transport.

Identical overlapping state queries share one collection. Four distinct state
collections may run at once; additional callers wait, and the last departing
waiter cancels its collection. Capacity stays occupied until collection exits.
Completed responses are not cached. Raw queries retain their existing duplicate
and semicolon handling.

New comparison cases in `dashboard_history_compact.py` check 86400 rows across
all, short, unknown and manual ranges. `dashboard_compact_interleave.py` forces a
live generation and clock change after capture, makes live getters fatal, and
requires the old frozen generation. `dashboard_history_concurrent.py` compares
the complete reference state with four and twelve concurrent Go responses,
requires one GET/POST collection and private envelopes below 1 MiB for its fixture.
Go tests separately assert that POST contains no history and cover cancellation,
the four-collection bound and eviction after completion.

These are functional regression checks, not fleet performance measurements or
proof of the appliance memory cap under every retained dataset. Share statistics
and other snapshot collections have not gained new bounds in this slice. The
separate benchmark session owns performance evidence.

## Signals and evidence identity

`00-prelude.sh` records the inherited ignored signal set before launching Go.
Fallback restores it immediately before execing Bash and strips the private
marker. `test_fallback_signals.py` pairs real launcher paths for ignored SIGPIPE
and SIGTERM. Removing the restoration in an isolated Go source copy fails both:
the mutant exits by signal while Bash returns 1 or 0 respectively.

```bash
python3 tests/go-parity/test_fallback_signals.py
PITHEAD_TEST_GO_BINARY="$PWD/.go-cache/signal-fallback-mutation/pithead" \
python3 tests/go-parity/test_fallback_signals.py
```

The normal binary passes two methods; the mutant fails both, as intended. Its
source copy removes `signal.Ignore` from fallback, with no working-source edit.

`frozen_reference.sh`, reached through `make test-go-frozen-parity`, materializes the starting source with `git archive`
in an ignored cache directory, builds its CLI, runs the original redaction and
parser suites at both sources, then runs `test_frozen_cli.py`. That new comparison
has two methods and forty byte/exit comparisons: thirty reference-selection and
ten Go cases covering help, version, dispatch and refusals. Both arms use the same
argv and VERSION input. Pinned SHA256 values verify the frozen CLI and VERSION;
an arbitrary self-comparison directory is rejected. It does not test lifecycle
operations. The bounded Go CI job now includes this target and the history cases.

As a negative control, setting `PITHEAD_PARITY_BASE="$PWD"` makes both frozen
comparison methods fail artifact-identity validation before comparing outputs.

The stack harness still removes `PITHEAD_IMPL` and `PITHEAD_GO_BINARY` after
`BASH_ENV` startup. Therefore `make test-stack` under Go selection does not prove
native sourced assertions. No native per-fragment call counts are claimed.
The port-added `test_cli.py`, version, persistence and payout comparison files
are now labeled supplementary in PARITY.md and the affected historical reports.

## Final checks

All commands use worktree-local Go/uv/npm caches and offline dependency resolution,
as described in [storage results](results-storage.md#commands-and-results).

| Check | Result |
|---|---|
| Frozen dashboard: from the archived `dashboard/`, run the supplied Python 3.11 interpreter with `-m pytest --cov=mining_dashboard --cov-report=xml --cov-report=term tests` | 3716 original tests passed; 97.42% Python coverage |
| `PITHEAD_IMPL=python make test-dashboard` | 3719 passed; 94.46% coverage |
| Go full command below | 3719 passed; 85.44% coverage |
| Reference-only / Go-only `make test-patch-coverage` | Fail at 67% / 83%, including the now-tracked native Python bridge |
| Go plus A/B coverage append command below, then the unchanged patch gate | Pass at 94%; all 34 changed measured files present |
| Focused overview / fleet / HTTP / storage targets | 202 / 151 / 34 / 357 passed; HTTP comprises 19 original tests plus 15 supplementary cases |
| `make test-go-frozen-parity` | Passed; original checks at both sources and forty supplementary CLI comparisons |
| `make test-go-native-guards test-go-env-write-parity` | Passed, including eleven supplementary env-writer methods left intact and reached through the new adapter |
| `go -C go test -race -count=1 ./...` and `go -C go vet ./...` | Passed |
| `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go -C go build -o "$PWD/.go-cache/review2035-linux-amd64/" ./cmd/...`, repeated for arm64 | Passed; compilation only |
| `PITHEAD_IMPL=bash make test` / `PITHEAD_IMPL=go make test` | Both stop at third-party cache Markdown lint, exit 2 |
| GNU-first `make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings lint-topology lint-yaml` | Passed with the documented starting-SHA file-budget override |
| Ruff check/format, changed Markdown with pinned rules, new adapter ShellCheck/shfmt and `git diff --check` | Passed |

```bash
PITHEAD_IMPL=go \
PYTEST_PLUGINS=dashboard_storage_plugin,dashboard_overview_plugin \
PYTHONPATH="$PWD/tests/go-parity:$PWD/dashboard" \
PYTEST_XDIST_AUTO_NUM_WORKERS=1 make test-dashboard

PYTEST_ADDOPTS="--cov=mining_dashboard --cov-append --cov-report=xml --cov-report=term" \
make test-go-dashboard-overview-parity test-go-dashboard-fleet-parity \
    test-go-dashboard-http-parity test-go-dashboard-storage-parity
make test-patch-coverage
```

The three tests beyond the frozen 3716 were added in the previous snapshot review;
all original dashboard test files remain unchanged. Original redaction, parser
and topology checks likewise remain unchanged. Only the explicitly requested
placeholder repairs modify earlier port-added tests.

The full local gate still encounters third-party Markdown files in the required
uv cache. No lint rule or Make check has been weakened. Linux runtime, Docker,
appliance and live fleet proof remain unavailable locally; compilation does not
establish them. Wizard/control, production selection and shipping integration
remain next, followed by remaining backend and CLI work.
