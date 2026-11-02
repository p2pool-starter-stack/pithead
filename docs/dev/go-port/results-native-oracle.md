# Full dashboard native-oracle launcher

The operator's 2026-11-02 20:30Z review correctly identifies the default
`PITHEAD_IMPL=go make test-dashboard` command as mixed. Its coverage result
does not establish native ownership: many original HTTP tests construct the
Python app without installing the Go state bridge. The existing total and patch
coverage gates remain unchanged and run separately.

## Selection and ownership

`make test-go-dashboard-native-oracle` adds nine launcher controls and a separate
original-suite run. The launcher enumerates the 248 Python test files present
under `dashboard/tests` at `a73ffced33800de9435779a9cabef53864455acb`. This is
the original 3716-case oracle; later port tests supplement it elsewhere. Original
test files and fixtures retain their bytes. Explicit test paths support focused
diagnostics, but the CI target uses the complete frozen file list.

Before test collection, one root pytest plugin installs the full dependency
chain of 39 dashboard adapters. It forces Go selection, removes inherited plugin
selection and filters and gives every adapter the selected native executable.
Both positive and blocklisted dashboard plugin arguments are rejected. The state
bridge must be registered before the HTTP proxy starts. Public Python state,
miner-connection, standby and metrics handlers become fatal, so a missing bridge
cannot quietly turn a native route test into a Python route test.

The session requires accepted native state, chart, metrics, view, fleet, overview
and network results. Network acceptance also requires a native operation and no
compatibility call during that adapter invocation. Other adapter claims require
fatal saved reference bodies.
The terminal report records accepted results and unexpected public reference
calls. This proves the adapter boundaries, while Python providers, clocks,
polling, scheduling and transaction orchestration remain hybrid. It does not
establish a childless native backend.

## Negative controls and CI

An isolated fake native executable serves HTTP and deliberately forwards a real
`/api/state` request to the public Python handler. That request is rejected by
the fatal handler, and the control asserts the reference call was observed.
A second fake native chart helper returns invalid output; the chart operation
fails rather than accepting a Python result. Neither control renames or mutates
the shared binary, and neither relies only on an executable-existence check.

The reusable Go workflow retains all existing checks and adds this target as a
separate step with a 15-minute limit. Its overall limit is 45 minutes to include
the extra original-suite run. The unchanged coverage command and its 80% and
90% thresholds remain in place.

The exact CI target passes on Linux ARM64: nine controls and 3716 original tests,
with the original battery completing in 529.34 seconds. A preceding one-worker
xdist run also passes in 250 seconds. The final run records 25
accepted state responses, 95 charts, 512 metrics, 777 view results, 1245 fleet
and resource results, 374 overview/badge results and 115331 network results.
Public Python fallback calls and unexpected adapter fallbacks are zero. Network
compatibility calls are zero in the original battery; the separate provider
compatibility control records one and does not count it as native acceptance.
The original test files and fixtures, application Go and dashboard Python sources
remain unchanged in this round.

GNU-first `make lint` passes on the final tree in 484.35 seconds, including
topology, shell formatting and file-budget checks. Earlier failed attempts
exposed formatter, synthetic-fixture path and file-size issues, all repaired
without new exemptions or relaxed limits.

The macOS diagnostics were interrupted and have no full passing verdict. Their one
observed failure was the original symlink-marker test's three-second child
timeout under load; the exact reference and strict reruns both pass. The long
exhaustive network case also passes, with 32,768 native calls. Intentional
provider compatibility is counted separately and does not count as native acceptance.
