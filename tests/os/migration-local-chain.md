# Provision migration fixture

The provision phase requires a disposable Monero-only database copy from an
existing managed nonproduction source. Devops verifies source identity, active
consumers, reservations, database-consistent capture, source recovery and available
capacity. The runner owns admission, guest capacity and staging. The dedicated
combined-chain fixture remains deferred; this test does not require its creation.

The runner supplies `PITHEAD_OS_MONERO_SNAPSHOT`, a private directory containing a
regular `data.mdb` and a regular `snapshot.json` with this receipt shape:

```json
{"schema": 1, "consistent": true, "height": 1, "sha256": "<64 lowercase hex characters>"}
```

`height` records the positive synced source height. `sha256` identifies the captured
database. The receipt asserts the verified capture procedure; the test checks the
receipt and bytes, then independently proves sync through the guest's local RPC.
Neither a receipt alone nor a dashboard release flag proves local-chain recovery.
Wallets, Tari databases and source lock files are not copied.

`PITHEAD_OS_MONERO_SNAPSHOT_GUEST_GIB` names the runner-reserved guest disk size
(40–8192 GiB). It must fit the database plus 40 GiB for the image and other provision
legs. The guest must also have database size plus 5 GiB free before transfer.
The reserved remote Tari inputs used by the existing node tests remain required.
The fixture never substitutes a remote Monero node.

The guest stops Monero and dependent mining services before installing the verified
copy beneath its data mount. Before upgrade, local RPC must report synchronized at
or above the captured height, services must be healthy, and fresh persisted state
must show an earned release and advancing stratum hashes. Verification reads the
database without seeding the release flag. The same proof runs after unattended
slot commit. Configuration restoration and same-version health-failure fallback
remain part of the provision phase. Missing, inconsistent or insufficient fixtures
fail the phase; they do not skip its assertions.
