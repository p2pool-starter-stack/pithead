# Wallet fixture supersession

The E2E wrapper retires an obsolete private wallet snapshot after proving that
its wallet identity matches the live fixture. Supersession is separate from
restoration: it never imports the old cache or changes the original restoration
receipt, snapshot metadata, archives, logs or artifacts.

## Caller contract

Invoke `tests/integration/lib/wallet_fixture_supersession.py` from its source
checkout, with the adjacent `wallet-fixture.py` available. Run as the snapshot
owner under bench-ci's idle exclusive reservation. The caller must first validate
commit-qualified original and successor jobs, same-bench ownership, a later
VERIFIED successor with `baseline_verified=true`, fresh baseline verification and
closed recovery references. The wrapper validates wallet evidence; it does not
query bench-ci or establish those job and reservation predicates. Request
references are audit context, never substitutes for wallet identity proof.

Send one JSON object on stdin (at most 16384 bytes); pass the baseline checkout,
original snapshot directory and original job directory as positional arguments:

```bash
python3 tests/integration/lib/wallet_fixture_supersession.py \
    "$BASELINE_CHECKOUT" "$ORIGINAL_SNAPSHOT" "$ORIGINAL_JOB_DIR" < "$REQUEST_JSON"
```

The job directory basename must equal `original_job`. The request has exactly
these fields; both commits are full lowercase 40-hex SHAs:

```json
{
  "schema": 1,
  "original_job": 12,
  "original_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "successor_job": 13,
  "successor_commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "recovery_issues": ["bench-ci#1249", "bench-ci#1264"]
}
```

Job IDs must be distinct positive integers. Supply 1–16 distinct recovery
references in `bench-ci#N` or `pithead#N` form. Duplicate or extra JSON fields,
invalid references, oversized input and unsafe evidence refuse the operation.

## Proof and transition

The wrapper validates owner-only snapshot metadata, the wallet archive digest,
its complete member manifest and the archived image digest. Refuse wallet archives
over 2 GiB plus 1 MiB tar overhead and image archives over 4 GiB. It requires the
baseline configuration fingerprint to match the original metadata and live
wallet container, the expected Compose-owned local volume and no other consumer.
Only `captured` or `import_verified` snapshots with an ARMED or NOT_PROVEN original
receipt can be retired. Active restoration and already-cleaned snapshots refuse.

Stop the live wallet with repeated SIGTERM and require graceful save proof.
Capture its prepared cache through a read-only volume mount. Equal encrypted
key-file SHA-256 digests establish identity directly. Otherwise open separate
archive and live copies in network-isolated, unprivileged containers using the
fixture's empty wallet-file password. Each copy lives on private tmpfs; there is
no live-volume mount, daemon connection or published RPC port. Require equal
primary-address AND view-key fingerprints. The RPC values never leave the
isolated container. Address equality alone cannot establish proof.

Opening each copy has a 660-second client limit. On interruption, request SIGTERM
and wait up to 600 seconds for its container to exit; never force-kill it. An
unproved stop refuses supersession. SIGTERM, SIGHUP and SIGINT enter the same cleanup path. Stop and remove a
capture helper before restarting the live wallet. Temporary live archives are
removed and a previously running live wallet is restarted on success or failure,
except when capture-helper cleanup remains unproved. In that case keep it stopped. A failed stop,
restart, archive validation or identity comparison cannot create a retirement
record. Refusals do not print wallet logs or input values.

On success, atomically write owner-only `supersession.json` in the original
snapshot directory and fsync it. The record contains `status: SUPERSEDED`, the
request, metadata/archive/original-receipt fingerprints and boolean identity
proof. Output that bounded record as JSON and exit 0. Identity output contains
only fingerprints and booleans. On refusal, exit 1 with:

```json
{"schema": 1, "status": "REFUSED", "identity_proven": false}
```

The snapshot directory lock serializes supersession calls. Retrying the same
request validates the retained original evidence and returns the existing record
without stopping the wallet again. Strict record/proof schemas refuse missing,
extra or inconsistent fields rather than echoing them. A changed request, receipt,
archive or metadata refuses the retry. A receipt-only SUPERSEDED transition is unsupported.

Restore and ordinary cleanup refuse a snapshot carrying a supersession record.
The original receipt remains ARMED or NOT_PROVEN, never VERIFIED. Retained
archives await a later explicitly authorized cleanup; supersession does not
provide that cleanup or authorize operational retirement.

## Verification

The mandatory integration selftest covers matching ciphertext, differing
ciphertext with equal address and view key, independent address/view-key refusal,
corrupt evidence, unsafe modes and symlinks, request binding, interrupted opening,
retries and archive preservation. The tier-4 lifecycle proof uses a separate
private snapshot, exercises the real offline opener twice, proves live ciphertext
identity, checks idempotence and retained evidence, and requires restoration
replay to refuse. It retains its proof archives in private job scratch and never
retires another job's fixture. On failure its JSON names a fixed `failed_stage`
label to identify the refused step without printing exception text or wallet data.
