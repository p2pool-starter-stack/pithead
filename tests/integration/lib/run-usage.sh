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
  --dir <path>           target stack dir, absolute or relative to SSH login (default: pithead).
                         Avoid literal ~, which the caller's shell expands.
  --pithead <cmd>        target CLI command (default: ./pithead; use "sudo ./pithead" for root).
MATRIX:
  --check                read-only current-state assertions, without apply or restore.
  --readiness            read-only: synced chains, snapshot FS, disk space, owner-only secrets,
                         dashboard localhost-only.
  --backup-only          take and validate a safety backup, then stop; exclusive of other phases
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
  --lifecycle            restart; apply must preserve secrets and chown root-owned data to the container uid;
                         also backup→restore and uninstall→setup checks.
  --reset-dashboard      `pithead reset-dashboard` wipes the .env-named dirs, recreates them owned by APP_UID,
                         leaves chains untouched and brings dashboard/p2pool back healthy; also forces a compose
                         failure to reach the friendly retry. DESTRUCTIVE-then-restored; requires --safety-backup.
  --safety-backup        back up before destructive scenarios; roll back on failure (down→restore→up).
                         Remove the archive on success; recommended for destructive runs.
                         Modifier only: scenarios and phases still run.
  --fault-injection      stop/SIGSTOP/remove monerod; assert down/unhealthy/missing verdicts and failover recovery.
                         Test read-only/ENOSPC DB verdicts, fail-closed firewall rollback, Tor outage/doctor,
                         clock drift, DNS and sidechain recovery. SSH or local; slow; destructive-then-restored.
  --fault-injection-ssh  run that phase's rx() calls over SSH; requires --fault-ssh-dest.
  --fault-ssh-dest <h>   SSH destination for that phase; e2e.sh supplies the bench's own alias.
  --image-upgrade <old-sha> <new-sha>
                         run `pithead upgrade` from a private candidate bundle against the running old images;
                         prove image revisions, chain-data/heights, secret categories, workers and mining.
                         DESTRUCTIVE; exact 40-hex commits; requires --safety-backup and --local.
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

Missing scenario inputs are reported SKIPPED; the canonical synced chain is never mutated.
EOF
}
