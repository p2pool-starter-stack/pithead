# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
usage() {
    cat <<'EOF'
Pithead integration test runner

USAGE:
  run.sh --host <user@host> [options]     drive the box over SSH
  run.sh --local            [options]     drive a stack on this machine

CONNECTION:
  --host <user@host>     SSH destination of the test server
  --identity <keyfile>   SSH private key (adds -i <keyfile>)
  --ssh-opt <opt>        extra ssh -o option (repeatable), e.g. --ssh-opt Port=2222
  --local                run against a stack on this machine instead of over SSH
  --dir <path>           the Pithead stack directory ON THE BOX, relative to the SSH login
                         dir or absolute (default: pithead). Avoid a literal ~ — your local
                         shell would expand it before the box sees it.
  --pithead <cmd>        how to invoke pithead on the box (default: ./pithead;
                         use "sudo ./pithead" if docker needs root there)

MATRIX:
  --check                NON-DESTRUCTIVE: assert the box's current live state only — no config
                         changes, no apply, no restore. The safe first run / health check.
  --readiness            NON-DESTRUCTIVE: assess whether the box is fit to be a release/
                         validation server (synced chains reusable, snapshot-capable FS, disk
                         headroom, secrets not world-readable, dashboard localhost-only).
  --scenario <name>      run only one scenario (see --list)
  --workers <n>          miners expected online while mining (default: 2)
  --no-mining-asserts    SKIP mining assertions (workers online, stratum hashes, cold-cache
                         mining recovery) and the Tor clearnet probe fault, which requires a
                         live miner. Each skip is logged; other assertions stay binding (#905).
  --remote-monero-host <h>  external node for the remote-mode scenario — a BARE host or IP, never
                            host:port (pithead appends the port itself, #1491)
  --remote-monero-rpc-port <p>  that node's RPC port, when it is not the default 18081
  --remote-monero-zmq-port <p>  that node's ZMQ port, when it is not the default 18083
  --remote-tari-host <h>  bare host or IPv4 address for an external Tari node (#103)
  --pruned-data-dir <d>  synced PRUNED monero data dir (enables the pruned case when the
                         box's baseline is full)
  --full-data-dir <d>    synced FULL monero data dir (enables the full case when the box's
                         baseline is pruned)
  --lifecycle            also run the lifecycle phase (restart, apply secret-preservation,
                         and the #255 ensure_owner migration: a root-owned file under a data
                         dir must be chowned to the container uid by apply)
  --reset-dashboard      also run the reset-dashboard phase (#2346): `pithead reset-dashboard`
                         wipes the .env-named dirs, not an unapplied config.json path (#139),
                         recreates them owned by APP_UID (#550), leaves the chains untouched
                         (height never rewinds), brings dashboard/p2pool back healthy, and a
                         forced real compose failure reaches the friendly retry message instead
                         of a bare errexit abort (#557). DESTRUCTIVE-then-restored; requires
                         --safety-backup so interruption restores the baseline and removes decoys.
  --safety-backup        take a `pithead backup` BEFORE the destructive scenarios; if anything
                         fails, automatically roll the box back to it (down → restore → up).
                         The archive is removed on success. Recommended for the destructive
                         matrix on a precious box. Also exercises backup/restore end-to-end.
  --fault-injection      also run the fault-injection phase: deliberately break monerod
                         (stop / SIGSTOP / remove) and assert pithead's status verdicts
                         (down / unhealthy / missing) and the failover→recovery cycle. Also
                         makes the dashboard data dir read-only and asserts /api/state flags
                         db_healthy:false, then restores it (#202), and forces a real
                         `iptables -I` failure and asserts the #270 firewall rolls back
                         fail-closed (no half-open ruleset). Also stops the tor container and
                         asserts no clearnet egress leaks while SOCKS is down AND that
                         `doctor` flags the outage loudly (#563), shadows timedatectl for a
                         real clock-drift verdict, and tmpfs-fills the dashboard data dir for
                         a real ENOSPC verdict (#383). DESTRUCTIVE-then-restored; works over
                         SSH and locally. Slow (healthcheck + node-health debounce).
  --image-upgrade <old-sha> <new-sha>
                         run `pithead upgrade` from a private candidate release bundle against
                         the already-running old images and prove image revision, chain-data and
                         height continuity, categorized secret fingerprints, workers, and mining
                         across the change. Both arguments must be exact 40-hex Pithead commits.
                         DESTRUCTIVE; requires --safety-backup and --local.
  --candidate-bundle <tar.gz> <sig> <trusted-cosign.pub>
                         private candidate bundle, detached signature, and external trust root.
                         Required with --image-upgrade; all paths must be absolute local files.
  --candidate-image-key <trusted-cosign.pub>
                         optional image trust root; defaults to --candidate-bundle's key.
  --xvb-routing-smoke    establish P2Pool routing, enable XvB at the donor tier, and poll the real
                         controller/proxy/dashboard through one bounded XvB→P2Pool transition,
                         then restore the original config. Requires --safety-backup, miners, a
                         recent PPLNS share, and xvb.enabled=true ALREADY in the box's config —
                         the gate moves an existing donor route, it does not turn XvB on for you.
  --alert-egress         also run the live alert-egress leg (#2266): drive `pithead test-alert`
                         through the real Tor SOCKS proxy, one leg per configured sink
                         (IT_TELEGRAM_BOT_TOKEN + IT_TELEGRAM_CHAT_ID, IT_NTFY_URL,
                         IT_WEBHOOK_URLS, IT_HEALTHCHECKS_PING_URL), asserting each answered.
                         An absent credential self-skips that sink (missing); a third party
                         refusing the dial reports as its own verdict, never a stack failure.
                         DESTRUCTIVE-then-restored.
  --mergemine-submit     also run the merge-mining submission leg (#2586, V6 of #1129): a
                         throwaway peerless P2Pool (IT_MM_P2POOL_VERSION, default v4.18.1) mines
                         against the box's monerod and a recording Tari node; Tari's own validator
                         (tests/integration/mergemine, built at the pinned Tari tag) judges each
                         submission and its legacy/mutated controls at 349,999/350,000/350,001
                         under mainnet rules. Leaves the live stack alone; needs local Monero.
  --tari-stranded        also run the stranded-Tari leg (#2464): a DROP rule in tari's own network
                         namespace (comment pithead-e2e-fault-tari-stranded) cuts it off from tor;
                         asserts amber from the first 0-peer reading, red + doctor non-zero + alert, no
                         automatic restart, then green without a restart once the rule is removed (the
                         dashboard detects and alerts only; remediation is #2827). About an hour; opt-in only.
                         DESTRUCTIVE-then-restored.
  --monero-stranded      also run the stranded-Monero leg (#2499): a DROP rule in monerod's network
                         namespace cuts it off from tor; every layer must read red, then green. Opt-in.
  --mergemine-localnet   also run the merge-mining acceptance leg (#2589, V5 of #1129): Tari's
                         testnet-target build of the pinned release runs LocalNet alone on an
                         internal docker network; a throwaway P2Pool (IT_MM_P2POOL_VERSION) mines on
                         it against the box's monerod, and every block P2Pool reports is read back
                         from the node's main chain with its parent. Leaves the live stack alone;
                         needs local Monero.
  --auth-fail-closed     also run the fail-closed auth phase (#153/#203): empty PROXY_AUTH_TOKEN
                         in .env and assert `pithead up` REFUSES to start (the live counterpart
                         to the tier-1 compose-config check), then restore the exact token and
                         recover. DESTRUCTIVE-then-restored; works in both ssh and local mode.
  --hardening            local-only: rootfs write refusal, control path-unit apply/refusal, Tor recovery.
                         DESTRUCTIVE-then-restored; enables then disables control (#377/#33/#424).
  --rotate-onion         rotate an isolated onion fixture; prove reachability, retirement and restore (#2345).
  --rigforge             also run the RigForge integration phase (#185/#235/#260): assert the
                         dashboard consumed a REAL rigforge rig's enriched feed and Worker Inspect
                         reads it. Non-destructive; self-skips if no rigforge rig is connected.
  --rigforge-control     run the real RigForge control, reversible-write, and upgrade legs.
                         DESTRUCTIVE-then-restored; local mode and an opted-in real rig required.
  --rig-host <h>         the borrowed rig's LAN host/IP for control dials — needed to inject a
                         workers.list[] descriptor when the box's baseline lacks one (#513/#514/#506).
  --rig-name <name>      exact borrowed rig NAME from its protected RigForge config.
  --rigforge-bootstrap-version <tag>  explicitly bootstrap that rig before feed-dependent checks.
  --rig-control-port <p> the rig's writable control API port (default: 8082, #185).
  --rotate-secrets       verify live new/old credentials and miner reconnection, then restore.
                         Requires --safety-backup; a reserved rig also needs a runner-owned recovery hold.
  --subnet               also run the moved-subnet phase (#201/#180), local mode only: bring the
                         stack DOWN then UP on a non-default network.subnet (10.84.0.0/24) — the one
                         axis a hot apply can't move — and assert the moved prefix reached .env, the
                         docker bridge, tor's render-at-start IP, monerod's envsubst'd proxy IP, the
                         dashboard SSRF CIDR, and the #344 onion vhost, then run the standard
                         running-state battery. DESTRUCTIVE-then-restored (down/up back to baseline).
  --keep                 do NOT restore the original config.json at the end (leaves the box
                         on the last scenario — useful for debugging)

OUTPUT:
  --out <dir>            where to write artifacts (default: tests/integration/results)
  --list                 print the scenario matrix and axis coverage, then exit
  -h, --help             this help

Scenarios whose prerequisites are missing (a full/pruned alt data dir, or a remote endpoint)
are reported SKIPPED — never silently dropped, never mutating the canonical synced chain.
EOF
}
