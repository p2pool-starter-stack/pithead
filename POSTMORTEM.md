# Postmortem: nine days of merge-mining behind a green `READY`

**Incident:** 2026-09-11 12:45Z–2026-09-20 05:30Z  
**Node:** Tari v1.20.0  
**Impact:** p2pool merge-mined against a forked/stale auxiliary node for about
8.5 days. At discovery the public tip was 348,684 and the node tip was
342,575: a 6,109-block gap.

## What happened

The node rejected a peer block because its previous hash did not match, kept
its own tip, and banned peers for 7,200 seconds. Canonical peers were then
rejected on contact. The loop produced 21,542 rejections and roughly 2,500
bans per day; connectivity was `OFFLINE (0/1 connections)` for most of each
hour.

The merge-mining card stayed green because `READY` described only p2pool's
gRPC channel to the node. The channel was usable even though the node's chain
was not current. p2pool accepted the auxiliary template and did not compare
the auxiliary tip with a trusted network tip.

## What each layer actually proved

| Layer | Signal | Proof provided | Missing assertion |
|---|---|---|---|
| Container healthcheck | `healthy` | process existed | node is syncing and on the canonical chain |
| `pithead status` | exit 0 | container health | protocol health |
| `pithead doctor` | no Tari line | nothing | Tari peer/sync/fork check |
| Merge-Mining card | `READY`, height, reward, difficulty | gRPC transport and template data | height freshness, peers, rejection/bans |
| Alerts/Telegram | no event | no configured event fired | stale/forked/peerless event |
| p2pool | jobs mined | aux template accepted | aux chain agrees with network |
| Container log | warnings/errors | failure evidence existed | log-derived signal and alert |

## Root cause and contributing factors

Root cause: the dashboard used a transport readiness state as node health and
rendered height without a trusted comparison. Contributing factors were a
process-only container check, no Tari line in `doctor`, no alert for peerless
or stale nodes, and p2pool's trust in the aux template.

## Health contract for every card

Cards must separate these states:

* **Transport:** can the client reach the service (`READY`)?
* **Process:** is the expected process alive?
* **Connectivity:** is there at least one usable peer?
* **Freshness:** is node height within the configured lag threshold of a
  trusted network height?
* **Chain integrity:** are fork/rejection/banning signals absent?
* **Evidence age:** are all measurements recent enough to use?

The card may be green only when all required checks have fresh evidence. A
missing comparison height is `UNKNOWN`, not healthy. A node with zero peers,
non-zero rejection/ban signals, or lag over policy is `UNHEALTHY`, regardless
of a ready gRPC channel. The reward and difficulty remain informational and
must not override health.

## Corrective actions

1. Add Tari sync, peer, and fork/rejection checks to `doctor` and the health
   endpoint; keep process/container health as a separate layer.
2. Make the Merge-Mining card render transport status separately from the
   derived node-health state, including node height, trusted height, lag,
   peer count, last successful sync, and evidence age.
3. Emit deduplicated alerts for stale, fork/rejection, peerless, and unknown
   states; route the same events to Telegram if configured.
4. Keep p2pool merge-mining eligibility gated on the auxiliary node's health
   contract, with a clear operator override and audit log.
5. Add regression tests for the incident values above and for missing,
   contradictory, and stale evidence.

## Verification

The reference evaluator in `tari_health/contract.py` implements the contract
and is covered by `tests/test_contract.py`. It intentionally treats
`channel_ready=True` as insufficient evidence for green.

