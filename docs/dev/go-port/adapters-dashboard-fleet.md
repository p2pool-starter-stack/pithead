# Fleet and host-resource parity adapter

The Python suites import their builders directly, so the additive
`tests/go-parity/dashboard_fleet_plugin.py` routes those imports to Go while
preserving signatures, config inputs and source/facade/worker-detail aliases.
It layers over the unchanged views, metrics, state and HTTP adapters. After their
coverage initialization it reapplies native bindings before collection.
When coverage is active, it reloads the resource module after tracing starts so
module setup is measured, then reinstalls the native functions. Resource
calculations in the unchanged suites continue to execute Go.

`dashboard_fleet_session.py` keeps one fleet and one resource helper per worker.
This avoids per-call process startup in the original 1000-cycle host-resource
cost test. Requests still execute the same Go builders with fresh input; results
are never memoized. The session has a response timeout, child cleanup and restart
after malformed input, with explicit close remaining terminal. Existing helpers
and adapters stay intact. New Go stream tests cover independent frames and errors.

Resource requests tag nonfinite values as non-numeric objects. Go applies the
original numeric validation and returns unavailable samples; the adapter does
not calculate resource states. Expected results restore the entire original
Python builder graph, including prior adapter layers.

`dashboard_fleet_compare.py` compares worker sorting/skips, RigForge freshness
and release hints, energy/prices, resource validation and capacity estimates.
It checks large integers, timestamp grammar, nonfinite inputs, stream PID reuse,
float formatting, whitespace in IP octets, error recovery and production input capture.
An HTTP ownership guard disables
the Python workers, energy and host-resource builders while Go state succeeds.
Production energy capture projects endpoint descriptors to names and wattage;
a regression excludes credentials and connection fields from that handoff.
`make test-go-dashboard-fleet-parity` adds these cases to unchanged resource,
infrastructure, RigForge, worker-inspect and state suites.

These adapters prove the selected builders, not native polling or storage.
Production worker-inspect assembly remains Python. Unsupported capacity integer
operands beyond exact float range and malformed composites retain Python fallback.
Appending coverage from the new A/B cases records their original-Python expected
calculations as well as the native comparisons; this is separate from Go-selected
suite coverage. The existing coverage gates and all existing tests stay intact.
