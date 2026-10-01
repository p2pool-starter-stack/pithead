# Backup-window results

Version 1 records the e2e wrapper's baseline safety backup before restoration.

## Emission and collection

`tests/integration/e2e.sh` initializes a result before argument validation and
preflight. Set `IT_BACKUP_WINDOW_DIR` to an existing, caller-owned absolute
directory without group/other write permission. The default is `CI_ARTIFACTS`,
then `TMPDIR`. No candidate deployment or target results directory is required.
Each invocation creates `backup-window-<32 lowercase hex characters>` with mode
0700; `result.json` is replaced atomically with mode 0600. The directory name's
suffix is the invocation identity, independent of any candidate or runner commit.

The wrapper prints compact JSON lines prefixed `PITHEAD_BACKUP_RESULT_V1 ` at
initialization, attempt admission and completion. Collect `result.json` and
`backup.log` beneath the invocation directory from the caller's artifact root.
Bench-ci already passes its job-owned `CI_ARTIFACTS`; these files therefore survive
wrapper EXIT restoration and are collected with the tier's artifacts. Use the last
validated result for that invocation. An interrupted invocation can retain
`attempted`/`unknown`; never infer completion from a started command. The stdout
record remains available if the final atomic file write fails.

`backup.log` contains the complete original command diagnostics after the wrapper's
existing credential/endpoint redaction and control-character removal, on success
and failure. The unsanitized transcript is not written to the artifact directory.
Artifact diagnostics remain private evidence, not text to interpolate into public
notifications. The result contains only fixed codes, hashes, UTC timestamps and
indexes into bounded health observations. A diagnostic failure never replaces the
original command exit or adds a backup/startup/recovery operation.

## Result fields

| Field | Version 1 meaning |
|---|---|
| `version`, `invocation` | Integer `1`; fresh 32-character lowercase hex correlation identity. |
| `attempt` | `not_run` or `attempted`. Check mode and pre-backup refusals remain `not_run`. |
| `outcome` | `unknown`, `succeeded` or `failed`; success requires command exit 0 and a readable archive that passes `tar -tzf`. |
| `backup_exit_code` | Original numeric command exit (0–255), or null before completion. Archive validation never rewrites it. |
| `reason` | `not_run`, `interrupted`, `command_failed`, `archive_valid` or `archive_invalid`. |
| `canonical_product`, `baseline_product` | Separately sampled executable SHA-256, checkout source commit and checkout cleanliness; unavailable fields are null. |
| `tor_event` | `tor_restart_failed` only when the shared restart boundary reports failure and observes Tor unhealthy; otherwise `unknown`. |
| `observation_channel` | `available`, `unavailable` or `invalid`. An invalid channel establishes no Tor event or execution. |
| `observations` | At most seven validated shared-boundary observations. |
| `execution` | `observed` only with retained, identified healthcheck execution inside this backup window; otherwise `unknown`. |
| `execution_observations` | At most 35 `{observation, check}` indexes identifying the exact retained health executions. |
| `diagnostics` | `availability`: `available` or `unavailable`; `artifact`: the invocation-relative `backup-window-<invocation>/backup.log` or null. |

The canonical executable is the one invoked for backup. The baseline executable
belongs to `RESTORE_DIR`, resolved from the live stack during preflight. Neither
identity is the candidate identity. A checkout commit is a source claim; a dirty
checkout, generated executable or release bundle must not be attributed by source
ancestry alone. The executable digest records the actual sampled file. Missing
Git metadata remains null, even if an executable digest is available.

A wallet prerequisite after a successful backup does not change `outcome` or
`tor_event`. An unsuccessful backup and the runner's final restoration verdict
are separate facts. This producer makes no final restoration claim. A Tor restart
failure followed by successful recovery can coexist with backup success.

## Shared-boundary observations

With a valid `PITHEAD_BACKUP_WINDOW_TOKEN`, the generated CLI prints compact JSON
lines prefixed `PITHEAD_BACKUP_OBSERVATION_V1 `. The wrapper supplies the fresh
invocation identity; ordinary backups leave observation disabled. Each observation
contains exactly these fields:

- `version`, `token`, `kind` (`backup_begin`, `restart_before`,
  `restart_succeeded`, `restart_failed`) and `observed_at` (UTC).
- `container_id`, `image_id` (Docker image object SHA-256), `health`
  (`healthy`, `unhealthy`, `starting`, `unknown`).
- `configured_test_sha256`: digest of the compact JSON healthcheck command array.
  No raw command/configuration enters the result.
- `implementation_sha256`: sampled in-container script digest when the configured
  command is exactly `CMD /usr/local/bin/healthcheck.sh`; otherwise null.
- `checks`: at most five `{start, end, exit_code}` records from Docker health
  history. Health output and raw control replies are excluded before transport.

`backup_begin.observed_at` bounds the start of the window. An execution is observed
only when its retained Start/End interval lies between that time and the sampling
observation's time, with container, image and configured-command identity present.
The referenced observation ties the execution to that container and configuration.
A sampled script digest describes the file at sampling time; it does not prove
those exact bytes executed or that an earlier image refresh exercised the check.
Missing history, identity or observation remains unknown. These records establish
execution and unhealthy state, not the cause of Tor's failure.

Samples use read-only Docker inspect and, for the recognized command, a script hash
read in the identified container. Each diagnostic command has a five-second timeout.
Configuration, identifiers, timestamps, fields and observation counts are validated;
unknown fields, unsafe identifiers, stale tokens and oversized frames invalidate the
channel. Only projected health metadata crosses the Docker transport. Diagnostic
sampling does not alter startup retries, locks, rig handling or restoration.

## Compatibility and fixtures

An older wrapper supplies no result: backup outcome and Tor execution remain
unknown. A new wrapper invoking an older canonical executable still records its
command outcome and archive validation, but has an unavailable observation channel.
Do not reconstruct events by matching timestamped transcript tails.

The consumer must validate version, invocation, fields, codes and relative artifact
references before using a record. `tests/integration/lib/backup-window.py` contains
the producer validator. The fixture constructors in
`tests/integration/selftest/test_backup_window.py` provide accepted and rejected
observations; `test_backup_window_boundary.py` exercises the shared boundary.
Run the registered selftest:

```bash
bash tests/integration/selftest/selftest-backup-window.sh
```

The fixtures cover changing transcripts, later wallet failures, missing archives,
unavailable observations, stale/malformed/private fields, atomic invocation freshness,
unsafe artifact references and diagnostic failure without loss of the original exit.
Tier 4 proof uses the narrow safety-backup phase through bench-ci on a pushed exact
commit. No induced Tor stall or unchanged diagnostic rerun is required.
