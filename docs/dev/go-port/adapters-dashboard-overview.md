# Overview and badge parity adapters

The new `tests/go-parity/dashboard_overview_plugin.py` layers over the unchanged
fleet, views, metrics, state and HTTP adapters. It redirects the existing direct
pool/network, raffle, update and badge builder imports to native Go, preserving
source and facade aliases. `make test-go-dashboard-overview-parity` runs 171
unchanged tests and the new comparison module.

The adapter reuses the existing JSON session transport for persistent overview
and badge helpers. Every request executes Go with fresh arguments. Expected
values restore the entire original Python graph; wrapper code supplies inputs
and never calculates native output. Existing wallet fixtures contain mock prefix
objects under a frozen clock, so the adapter converts those two display inputs
to strings before JSON. The original fixture and test remain unchanged.

Under coverage, the badge module is reloaded after tracing starts and the Go
bindings are restored before collection. Appended A/B coverage measures original
Python expected calculations separately from the Go-selected full suite.

`dashboard_overview_compare.py` checks display formatting, large share counts,
null raffle tiers, ordering, update suppression, header warnings and raw-input
capture. Its HTTP guard makes all six Python builders raise while the native
state handler still succeeds. New Go tests cover allowed fields, malformed
operation pairing and output assembly.

These adapters prove presentation contracts. Egress/topology derivation and Tor
probes stay Python; wallet-change KV reading/parsing stays Python. The Go
recent-change helper has adjacent unit tests over supplied KV snapshots only.
Earnings, polling, SQLite, wizard/control and container selection remain pending.
