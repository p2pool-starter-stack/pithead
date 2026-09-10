# Integration tests (`tests/integration/`)

End-to-end suite that drives a real, already-provisioned Pithead server through the config matrix
and asserts the stack behaves (issue
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

```
run.sh          entry point — connects (SSH or --local) and runs the matrix (+ --lifecycle,
                --fault-injection)
scenarios.sh    the declarative config matrix (data, not code)
lib.sh          shared helpers: target I/O, assertions, readiness waiters, redaction
lib/            sourced live-runner modules
selftest/       pure-logic self-tests (no server) — run in CI on every PR
tools/          operator utilities for preparing and inspecting a test bench
fakes/          controllable fake monerod/Tari + contract tests against the real clients
mini-stack/     docker overlay running the real dashboard + docker-control against the fakes
```

The live matrix here is tier 4 of the broader plan. See
[`docs/dev/testing-strategy.md`](../../docs/dev/testing-strategy.md) for all four tiers and the full
scenario catalog.

Quick start:

```bash
# Against a remote box over SSH
make test-integration ARGS="--host miner@10.0.0.5 --dir pithead"

# On the box itself
./run.sh --local --dir /home/miner/pithead --lifecycle

# Just the pure-logic checks (no server)
make test-integration-selftest
```

Full guide — provisioning the box, the safety model, the matrix, artifacts, and CI/release
wiring — is in [`docs/dev/integration-testing.md`](../../docs/dev/integration-testing.md).
