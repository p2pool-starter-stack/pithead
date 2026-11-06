# Integration tests (`tests/integration/`)

End-to-end suite that drives a real, already-provisioned Pithead server through the config matrix
and asserts the stack behaves (issue
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

```
run.sh          entry point — connects (SSH or --local) and runs the matrix (+ --lifecycle,
                --fault-injection, --image-upgrade, --xvb-routing-smoke)
scenarios.sh    the declarative config matrix (data, not code)
lib.sh          shared helpers: target I/O, assertions, readiness waiters, redaction
lib/            sourced live-runner modules (incl. the live-gates.sh upgrade/XvB gates and
                their live-*-support.sh trust, state-snapshot, and restore helpers)
selftest/       pure-logic self-tests (no server) — run in CI on every PR
tools/          operator utilities for preparing and inspecting a test bench
live-supervisor.sh  runs a destructive gate under systemd so a cancelled CI job cannot kill its
                rollback; live-supervised-run.sh is the unit it launches
fakes/          controllable fake monerod/Tari + contract tests against the real clients
mini-stack/     docker overlay running the real dashboard + docker-control against the fakes
```

The live matrix here is tier 4 of the broader plan. See
[`docs/dev/testing-strategy.md`](../../docs/dev/testing-strategy.md) for all four tiers and the full
scenario catalog. The Tor fault records bounded numeric mining-witness samples in the
harness transcript: accepted shares, worker count, worker hashrate and minimum uptime.
API failures are explicit; worker identities and raw responses are omitted. The five-minute
mining-continuity assertion remains unchanged.

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

## Fake stratum endpoint

`fakes/fake_stratum.py` serves JSON lines over TCP using the P2Pool login and submit
response shapes recorded in `fakes/contract/v1/PROVENANCE`. The job values are synthetic;
real xmrig-proxy compatibility remains unverified until the stub-only donation routing
phase runs in tier 4. It does not verify proof of work or mine to a project endpoint.

Use `FakeStratum()` as a context manager. Tests bind to loopback on an OS-assigned port.
`logins` records only the received `login`, `pass` and `agent` fields; `login` is the
pool user. Each login has a separate record. `fixture_metadata` contains `url` and
`coin` supplied by the fixture, not fields observed in the stratum protocol. Assert the
actual `url`, `user`, `pass`, `coin` and per-pool `socks5` at the controller configuration
boundary instead. `test_stratum_pool_contract.py` covers both route orders and Tor
choices there; `test_fake_stratum.py` separately proves traversal using
`FakeSocks.connected` and the login received by the stratum fake.

`mode="accept"` acknowledges submissions and increments `accepted`; `mode="reject"`
returns a low-difficulty error and increments `rejected`. `mode="silent"` records
submissions without replying, while still answering login. `mode="refuse"` or
`refuse=True` closes new connections. `submissions` records received submit parameters.
These modes simulate outcomes without validating hashes, session IDs or job IDs.

For a mini-stack container, explicitly request a non-loopback bind:

```bash
python tests/integration/fakes/fake_stratum.py --host 0.0.0.0 --port 3333 --mode accept
```

Without `--host`, standalone mode also binds only to loopback. It prints the bound
fixture metadata once on startup. Add `--log PATH` to append JSON-line login and submit
events for inspection. Logs include received login passwords: use synthetic test
credentials only. No mini-stack service is added here; the donation routing phase owns
its container wiring. Run the socket contracts with `make test-fakes`.
