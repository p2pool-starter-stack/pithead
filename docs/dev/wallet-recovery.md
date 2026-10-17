# Wallet fixture recovery

The operator interface that finishes the restore of a retained private wallet snapshot after the job
that captured it has ended. It restores the original fixture; [supersession](wallet-supersession.md)
retires it instead.

## When it applies

`e2e.sh` snapshots the prepared Monero wallet cache before a destructive run and records an `ARMED`
receipt in the job directory. Its EXIT restore imports the snapshot, runs the readiness gate, removes
the archives and records `READY` then `VERIFIED`. A job cancelled or killed before that leaves the
receipt `ARMED` (or `NOT_PROVEN` after a failed import) and the snapshot in the job's private scratch.
The runner cannot finish the restore itself: the generic restore does not apply to a source-checkout
baseline, and the readiness gate lives in this repository's harness.

## Caller contract

Run `tests/integration/lib/wallet_fixture_recovery.py` from its source checkout, as the snapshot
owner, with the adjacent `wallet-fixture.py`, `wallet_fixture_supersession.py` and
`wallet-fixture-recovery.sh` and the harness libraries they source. Pass the baseline checkout, the
snapshot directory and the original job directory, and one JSON request on stdin (at most 16384 bytes):

```bash
python3 tests/integration/lib/wallet_fixture_recovery.py \
    "$BASELINE_CHECKOUT" "$SNAPSHOT" "$ORIGINAL_JOB_DIR" < "$REQUEST_JSON"
```

```json
{
  "schema": 1,
  "original_job": 12,
  "original_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "recovery_issues": ["bench-ci#2019"]
}
```

The job directory basename must equal `original_job`. Supply 1 to 16 distinct references in
`bench-ci#N` or `pithead#N` form. Duplicate or extra fields refuse the request. The references are audit
context only; they never stand in for wallet evidence.

The caller owns the job and reservation predicates, as for supersession: a completed local job of the
expected commit, no job in progress, and the bench reserved. The wrapper does not query the runner. It
verifies the reservation instead of taking it when the runner holds the rig lock (`RIG_LOCK_PARENT_*`,
the same proof `e2e.sh` checks), and takes the rig lock itself otherwise. `E2E_DIR` (default
`/srv/code/pithead-e2e`) names the dedicated e2e checkout whose wallet container the recovery may also
replace. The baseline start is bounded at 3600 seconds and the readiness gate at 1800; a runner timeout of
7200 seconds covers the worst case with the import, and a typical run takes a fraction of it.

## Steps

1. Validate the request, the owner-only job directory and snapshot, the archive sizes, the receipt
   (`ARMED`, `NOT_PROVEN` or `READY`), that the baseline wallet identity in `.env` still equals the
   snapshot's, and the archive digests and manifest. A superseded fixture, an active helper container
   named for the snapshot, or a lock that does not verify refuses here.
2. Prove the live wallet before its volume is overwritten. With no wallet volume or no payout wallet in
   it, there is nothing to protect. Otherwise the supersession proof applies: equal encrypted key-file
   digests, or equal primary address and view key opened in isolated containers. A different wallet
   refuses and leaves the live wallet running.
3. `restore` with the wallet container stopped, as `e2e.sh` runs it. The helper containers are
   removed on an interrupt too.
4. Start the baseline through the command the e2e restore uses (`pithead upgrade` for a source
   checkout, `pithead apply -y` then `pithead up` for a bundle), after the same pre-restore convergence,
   and wait for synced chains, a healthy status and running mining services.
5. Run the same readiness gate (`assert_payout_wallet_ready confirmed Monero`): the 1200-second Monero
   catch-up and the 420-second authenticated dashboard and address checks.
6. Verify the lock again, write `READY`, run `cleanup` to remove the archives, then write `VERIFIED`.

`READY` is written from `ARMED`, `READY`, and (only here) `NOT_PROVEN`: the receipt state machine refuses
that last transition everywhere else, because only a full restore and the gate justify it. `VERIFIED`
is reachable only from `READY`.

## Verdict and refusals

Stdout carries one JSON object and nothing else. The shell steps and the restore log to stderr, which can
name containers and, when the wallet fails to stop, carry its last log lines. A refusal adds one stderr
line with its reason and the exception class, never the message. Success exits 0:

```json
{
  "schema": 1,
  "request": {"schema": 1, "original_job": 12, "original_commit": "aaaa…", "recovery_issues": ["bench-ci#2019"]},
  "status": "RESTORED",
  "proof": {
    "method": "encrypted_keys",
    "live_identity_proven": true,
    "import_verified": true,
    "wallet_ready": true,
    "archive_fingerprint": "<sha256>",
    "keys_fingerprint": "<sha256>"
  },
  "receipt_fingerprint": "<sha256 of VERIFIED>"
}
```

`method` is `encrypted_keys` or `isolated_open` (a live wallet was compared), `empty_volume` or
`no_volume` (nothing live to compare), or `resumed` (see below). The verdict holds booleans and sha256
fingerprints only: no address, view key, credential or path. The wrapper validates this closed shape
before it writes `READY`.

A refusal exits 1 with a fixed reason and no other text:

```json
{"schema": 1, "status": "REFUSED", "reason": "identity"}
```

| Reason | Cause |
|---|---|
| `request`, `evidence` | Malformed request, wrong argument count, or an unsafe or mismatched job directory, snapshot or archive size |
| `superseded`, `receipt`, `helper` | The fixture is retired, the receipt is not `ARMED`, `NOT_PROVEN` or `READY`, or a helper container for the snapshot is active |
| `identity`, `archive` | The baseline wallet identity changed or the live wallet is not the snapshot's; the archive or image digest, or the manifest, differs |
| `busy`, `lock` | The rig lock is held elsewhere, or the runner's lock no longer verifies |
| `import`, `startup`, `readiness` | The restore, the baseline start, or the readiness gate failed or timed out |
| `verdict`, `seal` | The verdict failed its own schema (before any receipt is written), or a receipt or cleanup write failed |
| `interrupted`, `internal` | SIGTERM, SIGHUP or SIGINT arrived, or an unexpected error occurred |

A refusal before the import leaves the receipt, the snapshot and its stage unchanged. After the import
started, a failure leaves the receipt (`ARMED`, `NOT_PROVEN` or `READY`) and the snapshot at stage
`restoring` or `import_verified`, so the same request retries from the top. `ARMED` and `NOT_PROVEN`
both keep the fence the runner holds.

## Retry and resume

An import interrupted at `restoring` re-imports from scratch on retry. A run that finished `cleanup`
but not the `VERIFIED` write leaves stage `ready` with the archives gone; the retry skips the import,
starts the baseline, runs the gate again and writes the receipts. A receipt left at `READY` retries the
same way.

## Verification

`tests/integration/selftest/selftest-wallet-recovery.sh` runs without Docker or a wallet. The Python
tests (`test-wallet-recovery.py`, `test-wallet-recovery-interface.py`) cover the success path, an
interrupted import resumed from `restoring`, a corrupt archive, a wallet identity that does not match
(configuration and live), a superseded fixture, an active helper, unsafe receipts and job directories,
a failed start or gate, a failure after `READY`, the stage `ready` resume, the closed request and verdict
schemas, the rig lock, and the process-group stop on a timeout. The shell checks cover the start
command for a source checkout and a bundle, the reused readiness gate and the lock verification. The
live path (real Docker, the baseline start and the gate) is proved only on a reserved bench.
