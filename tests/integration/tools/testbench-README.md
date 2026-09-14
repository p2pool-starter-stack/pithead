# Pithead reference build & test server

A dev and test box that runs the live Pithead stack (Monero node + P2Pool + Tari merge-mining +
dashboard) against real, synced chains, and serves as the Tier-4 release gate: changes are
validated end-to-end here before release. This guide covers how to provision and run your own;
substitute your own host, user, and paths throughout. The examples assume the host is reachable
over SSH as `$BENCH_HOST`.

See `docs/dev/test-server-architecture.md` for the full architecture and how to stand a box up from
scratch.

**This file is the generic twin, and it is meant to differ from the copy on a running box.** A real
bench keeps its own README naming that box's hosts, users and paths — the detail an operator needs
and the detail this repo must not carry. Neither copy can be synced onto the other: syncing this way
would publish a topology, and syncing the other way would delete what the box runs on. Reconcile the
two by hand, fact by fact, or leave them alone (#1506).

## ⚠️ Golden rules

This is a test bench, not a production miner — downtime and teardown/redeploy are fine. The
constraints that matter:

1. **Never lose the synced chains.** They are the only slow-to-acquire asset (days to re-sync), so
   reuse them. Keep them in a data directory decoupled from the checkout (e.g. a sibling
   `pithead-data/` dir) so you can refresh or redeploy the stack without touching them.
2. **Chains on fast storage, OS on its own disk.** Put the chains on an NVMe SSD — monerod's LMDB
   is random-read heavy, so it opens a multi-hundred-GB database in seconds there and crawls on a
   slow SATA SSD or HDD. Mount the chain volume by UUID with `noatime` and `nofail`. Keep the OS
   and Docker on a separate disk so a chain-volume problem can't take the box down.
3. **Least privilege.** Keep `sudo` password-protected and interactive — don't leave passwordless
   grants lying around. Almost nothing here needs sudo if your user is in the `docker` group.
4. **Secrets stay put.** `.env` (RPC creds) and `config.json` (wallet addresses) are owner-only.
   Never print, copy, or commit them.

## Where things are

A workable layout (adjust to taste):

| Path | What |
|---|---|
| `<checkout>/` (e.g. `/srv/code/pithead`) | the stack checkout: `docker-compose.yml`, the `pithead` CLI, your `config.json`/`.env` |
| `<data-dir>/{monero,tari,p2pool,dashboard,tor}/` (e.g. `/srv/code/pithead-data`) | the chains — the asset, on the NVMe, decoupled from the checkout |
| `<tools-dir>/` | build-server docs and chain-ops tools (the `*.sh` helpers are also versioned in the repo under `tests/integration/`) |
| `<tools-dir>/bin/monero-blockchain-prune` | the verified offline Monero tool, version-matched to monerod |

## The chains

- **Monero is pruned** (`MONERO_PRUNE=1`) and sits at ~258 GiB, its true compact size here —
  measured ([#1446](https://github.com/p2pool-starter-stack/pithead/issues/1446)). **Size alone
  does not diagnose bloat: read the freelist.** `mdb_stat -ef` on an idle copy reports 10 free
  pages out of 67,605,667, and `pages_used * 4096` equals the file size exactly, so the file is
  dense and compacting it would reclaim nothing. An earlier version of this line promised
  "~95 GiB" and told you to compact anything reading ~250 GiB; that figure was never measured.
  This copy alone does not establish normal pruned-node sizing: source and copy were both measured
  with `pruning_seed=384` ([#1502](https://github.com/p2pool-starter-stack/pithead/issues/1502)), so
  `--copy-pruned-database` copied `txs_prunable` and `txs_prunable_tip` verbatim instead of running
  the prune routine
  ([source](https://github.com/monero-project/monero/blob/v0.18.5.1/src/blockchain_utilities/blockchain_prune.cpp#L584-L627)).
  The user-facing budget instead follows the independent node that enabled pruning at genesis and
  consumed 285.8 GB after syncing. Its first-start log enters the zero-seed branch that creates the
  seed and aborts initialization if pruning fails; synchronization then continued from genesis. A
  direct freelist read would classify its pages but would not reduce the disk space `data.mdb`
  occupies. This bench's dense 276.9 GB copy corroborates that footprint
  ([#1502](https://github.com/p2pool-starter-stack/pithead/issues/1502)).
- **`MDB_VERSION_MISMATCH` from a system LMDB tool is the lock-file format, not a patched data
  format, and not corruption.** It appears while monerod holds the environment; the same tool
  opens an idle copy of the same chain. Measured here on monerod 0.18.5.1, where both DBs read
  magic `0xbeefc0de`, version 1 (#1446) — one bench, one build. Do not stop monerod over it. `monero-blockchain-prune` remains the tool that compacts a Monero chain.
- **Tari is archival/full** (~132 GiB, no pruning configured). That size is genuine data, not
  bloat, so there is nothing to compact. Shrinking it would mean pruning Tari (a config change plus
  re-sync), which is a product decision, not housekeeping.

**Compacting the Monero chain** — only when the freelist shows pages to reclaim (takes hours, no
downtime for the copy).

`monero-blockchain-prune` is copy-then-swap: once it has built `lmdb-pruned` it renames `lmdb` to
`lmdb-old` and moves the pruned DB into place itself (#1489). Pointed straight at a live data dir
that renames the live chain out from under a running monerod, silently until the next restart. So
run it against a bind mount, which makes the kernel refuse that rename:

```bash
mkdir -p <build-dir>/lmdb
sudo mount --bind <data-dir>/monero/lmdb <build-dir>/lmdb
mv <build-dir>/lmdb <build-dir>/x   # MUST answer "Device or resource busy" — prove the guard first
tests/integration/tools/compact-chain.sh <build-dir>   # monerod stays up; result at <build-dir>/lmdb-pruned
```

Then swap the compact copy in (brief downtime):

```bash
docker stop monerod
sudo umount <build-dir>/lmdb
cd <data-dir>/monero && mv lmdb lmdb.bloated && mv <build-dir>/lmdb-pruned lmdb
docker start monerod        # re-syncs the few blocks added during the copy
# confirm `pithead status` healthy, then: rm -rf lmdb.bloated
```

## Running the stack

```bash
cd <checkout>
./pithead status         # health summary
./pithead doctor         # deeper diagnostics
./pithead up | down | apply | backup
```

## Running the test harness (the point of this box)

Tiers 1–3 run anywhere with no real chains; Tier 4 (the live matrix) runs here.

```bash
# Drive the test bench over SSH from a dev checkout (start non-destructive):
tests/integration/run.sh --host "$BENCH_HOST" --dir <checkout> --check       # assert current live state
tests/integration/run.sh --host "$BENCH_HOST" --dir <checkout> --readiness   # is the box fit to gate a release?
# Full destructive config matrix, with a pithead backup + auto-rollback on failure:
tests/integration/run.sh --host "$BENCH_HOST" --dir <checkout> --safety-backup
# On the box itself:
cd <checkout> && tests/integration/run.sh --local --dir "$PWD" --lifecycle
```

Always start with `--check`/`--readiness`. Use `--safety-backup` for the destructive matrix so a
failure rolls the box back (down → restore → up). See `docs/dev/integration-testing.md`.

## End-to-end coverage: validated live vs. gaps

**Validated live (Tier 4):** the config matrix (remote/local node, dashboard secure/insecure, Tari
required/optional, RPC LAN access, XvB on/off) applied and asserted on real synced chains;
lifecycle (restart, secret-preserving `apply`, same-version backup→restore round-trip); node-down failover and
recovery; release readiness; pruned monerod (the common production config); and the privacy egress
assertions. [#274](https://github.com/p2pool-starter-stack/pithead/issues/274) promoted the persistent direct-IPv4-TCP bridge-container observation, and [#206](https://github.com/p2pool-starter-stack/pithead/issues/206)
added the running XvB-over-Tor configuration assertion. Together with the historical live evidence
from [#274](https://github.com/p2pool-starter-stack/pithead/issues/274), privacy egress is covered,
with the stated IPv4-TCP/bridge-network limit, not a residual gap.

**Covered without a real chain:** client↔daemon contract tests, the fake-daemon mini-stack
(including full-prune behavior), compose hardening, config rendering, dashboard unit/frontend tests.

| # | Gap (not tested live) | Worth filling before release? |
|---|---|---|
| 1 | Full (unpruned) Monero mode live — a pruned bench can't cover it | Low. Stack code paths don't differ by prune mode (it's monerod-internal); fakes/config cover it. A multi-day full sync isn't justified. |
| 2 | Protected pre-release gate — a self-hosted runner is manual/opt-in | Medium-high, high-value. Keep `workflow_dispatch` restricted to the protected default branch and approved actors; it is not a required PR check. |
| 3 | Cross-version self-deploy upgrade | Medium. Run the upgrade proof tracked by [#1997](https://github.com/p2pool-starter-stack/pithead/issues/1997), blocked by its runnable-environment issue [#2057](https://github.com/p2pool-starter-stack/pithead/issues/2057). It proves signed-bundle image identity, exact mounts, chain anchors, durable DB state, secrets, workers/mining, and exact old-release restoration. |
| 4 | Cross-version appliance/RAUC upgrade | Medium. The current KVM update builds both slots from one tree; [#2056](https://github.com/p2pool-starter-stack/pithead/issues/2056) tracks an upgrade from a real previous appliance release with provisioned state. |
| 5 | N-1 encrypted backup restore on the appliance | Medium. Same-version restore is covered; [#2001](https://github.com/p2pool-starter-stack/pithead/issues/2001) tracks restoring a supported prior-release backup through the current wizard without a forced resync. |
| 6 | XvB route record | Medium. Run the gate tracked by [#1998](https://github.com/p2pool-starter-stack/pithead/issues/1998). The routing transition has no recorded live proof. |
| 7 | Caddy-fronted `/metrics` with dashboard authentication | Medium. Needs `IT_DASHBOARD_PASSWORD` (env; the box's real dashboard login plaintext) — see `docs/dev/integration-testing.md`'s `--check` row for the exact bench-ci knob. Tracked by [#2058](https://github.com/p2pool-starter-stack/pithead/issues/2058), open until an operator sets it and a run shows the leg executing. |
| 8 | Multi-worker scale — the harness assumes ~2 workers | Medium. For perf confidence add a load-gen worker and assert proxy routing/hashrate; [#1999](https://github.com/p2pool-starter-stack/pithead/issues/1999) tracks it. |
| 9 | Real Tari merge-mined block acceptance | Low. Finding a block is probabilistic; rely on template/connectivity checks. |
| 10 | Fault injection over SSH — implementation exists, recorded evidence does not | Low-Medium. The faults already route through `rx`; [#2000](https://github.com/p2pool-starter-stack/pithead/issues/2000) owns a focused remote quoting/cleanup/restoration proof. |

**Recommended before release:** record the combined upgrade/XvB run, then automate the protected
gate when a self-hosted runner exists. The rest are nice-to-have.

## Notes for AI agents

- SSH from a sandboxed agent needs the LAN allowance (e.g. `dangerouslyDisableSandbox`) when the
  test bench is on the LAN.
- Avoid literal `( )` in remote command strings — they break the non-interactive remote shell.
- `pkill -f <pattern>` self-matches your own command line — kill by PID, or use the `[x]`-bracket trick.
- Don't stop monerod without reason; check `docker ps` health first and narrate any downtime.
- Long jobs: launch detached (`nohup … &`) and poll a status file; SSH sessions drop.
