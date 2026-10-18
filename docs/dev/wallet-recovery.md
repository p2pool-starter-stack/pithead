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
owner, with the files it loads and sources kept at their relative layout: `tests/integration/lib.sh`
and, in `tests/integration/lib/`, the Python files `wallet-fixture.py` and
`wallet_fixture_supersession.py` and the scripts `wallet-fixture-recovery.sh`, `chain-keep.sh`,
`parent-lock.sh`, `readiness-churn.sh`, `redact-it-password.sh`, `remote-endpoints.sh`,
`reset-restore-web.sh`, `restore-mining-ready.sh`, `run-tari-wallet.sh`, `skip-accounting.sh` and
`wallet-diagnostics.sh`. Pass the baseline checkout, the snapshot directory and the original job
directory, and one JSON request on stdin (at most 16384 bytes):

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
replace. The baseline start is bounded at 3600 seconds and the readiness gate at 1800. A typical run takes a
fraction of 7200 seconds, the runner timeout to start from; the bounded steps alone (image loads, the
live-wallet proof, two graceful stops, the start and the gate) can add up to more. A timeout lands as
`interrupted`, which the same request resumes.

## Steps

1. Validate the request, the owner-only job directory and snapshot, the archive sizes, the receipt
   (`ARMED`, `NOT_PROVEN` or `READY`), that the baseline wallet identity in `.env` still equals the
   snapshot's, and the archive digests and manifest. The manifest must name exactly one prepared wallet
   pair, and the archive and keys fingerprints the verdict will carry are read and checked now, before
   anything changes. A superseded fixture, an active helper container named for the snapshot, or a lock
   that does not verify refuses here.
2. Prove the live wallet before its volume is overwritten, on a snapshot whose import has not started
   (stage `captured`). With no wallet volume or no payout wallet in it, there is nothing to protect.
   Otherwise the supersession proof applies: equal encrypted key-file digests, or equal primary address
   and view key opened in isolated containers. A different wallet refuses and leaves the live wallet
   running. A retry after the import started (stage `restoring` or `import_verified`) skips the proof:
   the volume is already the snapshot's to overwrite, and the baseline identity in step 1 binds it.
3. `restore` with the wallet container stopped, as `e2e.sh` runs it. The helper containers are
   removed on an interrupt too.
4. Start the baseline through the command the e2e restore uses (`pithead upgrade` for a source
   checkout, `pithead apply -y` then `pithead up` for a bundle), after the same pre-restore convergence,
   and wait for synced chains, a healthy status and running mining services.
5. Run the same readiness gate (`assert_payout_wallet_ready confirmed Monero`): the 1200-second Monero
   catch-up and the 420-second authenticated dashboard and address checks.
6. Verify the lock again, write `READY`, run `cleanup` to remove the archives, then write `VERIFIED`.

The start does not run `recreate_test_checkout_containers` or `verify_restore_proof`, which `e2e.sh`
runs before it verifies the wallet, so `VERIFIED` vouches for the wallet only: the caller proves the rest
of the baseline stack before relying on it.

`READY` is written from `ARMED`, `READY`, and (only here) `NOT_PROVEN`: the receipt state machine refuses
that last transition everywhere else, because only a full restore and the gate justify it. `VERIFIED`
is reachable only from `READY`.

## Verdict and refusals

Stdout carries one JSON object and nothing else. The shell steps and the restore log to stderr, which can
name containers and, when the wallet fails to stop, carry its last log lines. For a bundle baseline the
start step runs `pithead apply -y` and `pithead up`, which print the stratum access password in clear
when one is set (`announce_stratum_auth` in `lib/pithead/13-announce.sh`). `redact` in
`tests/integration/lib.sh` does not mask that line, so stderr must stay private: send it to an owner-only
file, never to a job log or any other stream the runner publishes. A source-checkout baseline starts with
`pithead upgrade`, which prints no password; the lifecycle leg's baseline is a source checkout, so the
log tail it prints through `redact` on a failure carries none.

A refusal adds one stderr line with its reason and the exception class, never the message. Success
exits 0:

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
`no_volume` (nothing live to compare), or `resumed` (no live comparison in this run; see below). The
verdict holds booleans and sha256 fingerprints only: no address, view key, credential or path. The
wrapper validates this closed shape before it writes `READY`.

A refusal exits 1 with a fixed reason and no other text:

```json
{"schema": 1, "status": "REFUSED", "reason": "identity"}
```

| Reason | Cause |
|---|---|
| `request`, `evidence` | Malformed request, wrong argument count, or an unsafe or mismatched job directory, snapshot or archive size |
| `superseded`, `receipt`, `helper` | The fixture is retired, the receipt is not `ARMED`, `NOT_PROVEN` or `READY`, or a helper container for the snapshot is active |
| `identity`, `archive` | The baseline wallet identity changed or the live wallet is not the snapshot's; the archive or image digest, or the manifest, differs |
| `pair` | The snapshot does not name exactly one prepared wallet pair (several retained pairs, or no keys file), or a recorded archive or keys fingerprint is missing or malformed |
| `busy`, `lock` | The rig lock is held elsewhere, or the runner's lock no longer verifies |
| `import`, `startup`, `readiness` | The restore, the baseline start, or the readiness gate failed or timed out |
| `verdict`, `seal` | The verdict failed its own schema (before any receipt is written), or a receipt or cleanup write failed |
| `interrupted`, `internal` | SIGTERM, SIGHUP or SIGINT arrived, or an unexpected error occurred |

A refusal before the import leaves the receipt, the snapshot and its stage unchanged. After the import
started, a failure leaves the receipt (`ARMED`, `NOT_PROVEN` or `READY`) and the snapshot at stage
`restoring` or `import_verified`, so the same request retries from the top. `ARMED` and `NOT_PROVEN`
both keep the fence the runner holds.

## Retry and resume

An import interrupted at `restoring` re-imports from scratch on retry, whatever state the wallet
consumer is in by then (removed, exited non-zero, or still scanning), and reports `resumed`. A run that
finished `cleanup` but not the `VERIFIED` write leaves stage `ready` with the archives gone; the retry
skips the import, starts the baseline, runs the gate again and writes the receipts. A receipt left at
`READY` retries the same way.

## Verification

`tests/integration/selftest/selftest-wallet-recovery.sh` runs without Docker or a wallet. The Python
tests (`test-wallet-recovery.py`, `test-wallet-recovery-interface.py` and
`test-wallet-recovery-live.py`) cover the success path, an interrupted import resumed from
`restoring`, a corrupt archive, a wallet identity that does not match (configuration and live), a live
wallet in the e2e checkout or a third one, a retry after the import began with the consumer gone, a
superseded fixture, an active helper, unsafe receipts and job directories, a failed start or gate, a
failure after `READY`, the stage `ready` resume, a snapshot with several retained wallet pairs and a
tampered recorded fingerprint refused as `pair` before any lock, start or import with the receipt and
stage unchanged, a verdict that fails its schema refused as `verdict`, the closed request and verdict
schemas, the rig lock held for the whole run, and the process-group stop on a timeout. The shell checks
cover the start command for a source checkout and a bundle, the reused readiness gate and the lock
verification.

The live path (real Docker, the baseline start and the gate) is proved by the lifecycle phase on a DIY
checkout, as a `tier4-e2e` job with `phases: [lifecycle]` on the PR's head and a borrowed miner. The
phase runs `tests/integration/tools/prove-wallet-recovery.py` after the supersession proof, on the
harness's own prepared wallet and never on another job's evidence:

1. Wait for the running wallet's scan marker to clear, then capture a private snapshot and record an
   `ARMED` receipt in a job directory of the proof's own, as a cancelled job leaves them. Refuse
   `VERIFIED` from `ARMED`, so a `VERIFIED` receipt later proves `READY` was written first.
2. Run `wallet_fixture_recovery.py` as a subprocess with the documented arguments and request. Its
   standard error goes to a private log in the proof's scratch. When no runner lock is claimed the
   harness already holds the rig lock, so the recovery locks a private file instead of contending with
   its own ancestor; a claimed runner lock and its descriptor pass through unchanged. A run is limited to
   7200 seconds and is stopped with `SIGTERM`, never killed.
3. Require the verdict to be valid, to echo the request, to carry the snapshot's own archive and keys
   fingerprints, and to report a live comparison (`encrypted_keys` or `isolated_open`) with the import
   verified and the wallet ready.
4. Require the `VERIFIED` receipt; only `state.json` left in the snapshot with stage `ready`; only the
   receipt in the job directory; no helper container for the snapshot and no proof directory left.
5. Run the same request again and require the refusal `receipt`.

`selftest-wallet-recovery-proof.sh` covers the proof's plumbing, assertions and failure labels and the shell
leg without a bench. `selftest-lifecycle-gate-wiring.sh` requires a failed proof to end `run_lifecycle` with
a non-zero status before the next boundary sample.

The shell leg then waits for `pithead status` to report OK and runs the payout-wallet gate once more
in the harness's own accounting. The proof prints fixed stage labels and, on failure, one JSON object
with a fixed `failed_stage` and `failure_reason`, the recovery's own closed refusal reason, and the log
path; the shell leg prints that object and the last 40 log lines through `redact`. A failed proof
leaves the snapshot at its stage and the receipt `ARMED`, so the same request retries from the top, and
ends the lifecycle phase. The wrapper's restore of its own snapshot still runs at the end of the job.
Appliance lifecycle runs record a named `by-design` skip because the proof tool is not shipped in the
image; on DIY a missing tool fails.
