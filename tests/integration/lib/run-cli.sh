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
  --no-mining-asserts    SKIP the two mining assertions (workers online, stratum hashes) with a
                         logged notice — for a box with no miner connected (e2e --no-miner, #905).
                         Every other assertion stays binding.
  --remote-monero-host <h>  external node for the remote-mode scenario — a BARE host or IP, never
                            host:port (pithead appends the port itself, #1491)
  --remote-monero-rpc-port <p>  that node's RPC port, when it is not the default 18081
  --remote-monero-zmq-port <p>  that node's ZMQ port, when it is not the default 18083
  --remote-tari-host <h>  external Tari node endpoint for the tari.mode=remote scenario (#103;
                         e.g. an already-synced Tari node on the LAN)
  --pruned-data-dir <d>  synced PRUNED monero data dir (enables the pruned case when the
                         box's baseline is full)
  --full-data-dir <d>    synced FULL monero data dir (enables the full case when the box's
                         baseline is pruned)
  --lifecycle            also run the lifecycle phase (restart, apply secret-preservation,
                         and the #255 ensure_owner migration: a root-owned file under a data
                         dir must be chowned to the container uid by apply)
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
                         a real ENOSPC verdict (#383). DESTRUCTIVE-then-restored; local mode
                         only. Slow (healthcheck + node-health debounce).
  --auth-fail-closed     also run the fail-closed auth phase (#153/#203): empty PROXY_AUTH_TOKEN
                         in .env and assert `pithead up` REFUSES to start (the live counterpart
                         to the tier-1 compose-config check), then restore the exact token and
                         recover. DESTRUCTIVE-then-restored; works in both ssh and local mode.
  --hardening            also run the v1.4 hardening phase (#377/#33/#424), local mode only:
                         read-only rootfs rejects writes live, the systemd control path unit fires
                         on a spooled request (allowlisted change applies, sensitive change
                         refused), and the stack recovers from a tor restart. DESTRUCTIVE-then-
                         restored (enables then disables the control channel).
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

# --- Arg parsing ------------------------------------------------------------
# shellcheck disable=SC2034  # the data-dir / remote-host globals are consumed by lib.sh:resolve_overrides
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --host)
            IT_SSH_DEST="$2"
            IT_MODE="ssh"
            shift 2
            ;;
        --identity)
            IT_SSH_OPTS+=(-i "$2")
            shift 2
            ;;
        --ssh-opt)
            IT_SSH_OPTS+=(-o "$2")
            shift 2
            ;;
        --local)
            IT_MODE="local"
            shift
            ;;
        --dir)
            IT_REMOTE_DIR="$2"
            shift 2
            ;;
        --pithead)
            IT_PITHEAD="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --readiness)
            READINESS=1
            shift
            ;;
        --scenario)
            ONLY_SCENARIO="$2"
            shift 2
            ;;
        --workers)
            EXPECTED_WORKERS="$2"
            shift 2
            ;;
        --no-mining-asserts)
            SKIP_MINING_ASSERTS=1
            shift
            ;;
        --remote-monero-host)
            case "${2:-}" in
            *:*)
                it_err "--remote-monero-host takes a BARE host or IP, not host:port — pithead renders the port separately (--remote-monero-rpc-port). Got \"$2\"."
                exit 2
                ;;
            esac
            REMOTE_MONERO_HOST="$2"
            shift 2
            ;;
        --remote-monero-rpc-port | --remote-monero-zmq-port)
            case "${2:-}" in
            "" | *[!0-9]*)
                it_err "$1 takes a TCP port 1-65535. Got \"${2:-}\"."
                exit 2
                ;;
            esac
            if [ "$2" -lt 1 ] || [ "$2" -gt 65535 ]; then
                it_err "$1 takes a TCP port 1-65535. Got \"$2\"."
                exit 2
            fi
            if [ "$1" = "--remote-monero-rpc-port" ]; then
                REMOTE_MONERO_RPC_PORT="$2"
            else
                REMOTE_MONERO_ZMQ_PORT="$2"
            fi
            shift 2
            ;;
        --remote-tari-host)
            REMOTE_TARI_HOST="$2"
            shift 2
            ;;
        --pruned-data-dir)
            PRUNED_DATA_DIR="$2"
            shift 2
            ;;
        --full-data-dir)
            FULL_DATA_DIR="$2"
            shift 2
            ;;
        --lifecycle)
            RUN_LIFECYCLE=1
            shift
            ;;
        --fault-injection)
            RUN_FAULTS=1
            shift
            ;;
        --auth-fail-closed)
            RUN_AUTH_FAIL_CLOSED=1
            shift
            ;;
        --hardening)
            RUN_HARDENING=1
            shift
            ;;
        --rigforge)
            RUN_RIGFORGE=1
            shift
            ;;
        --rigforge-control)
            RUN_RIGFORGE_CONTROL=1
            shift
            ;;
        --rig-host)
            RIG_HOST="$2"
            shift 2
            ;;
        --rig-name)
            RIG_NAME="$2"
            shift 2
            ;;
        --rigforge-bootstrap-version)
            RIGFORGE_BOOTSTRAP_VERSION="$2"
            shift 2
            ;;
        --rig-control-port)
            RIG_CONTROL_PORT="$2"
            shift 2
            ;;
        --subnet)
            RUN_SUBNET=1
            shift
            ;;
        --safety-backup)
            SAFETY_BACKUP=1
            shift
            ;;
        --keep)
            KEEP_STATE=1
            shift
            ;;
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        --list)
            print_list
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            it_err "Unknown option: $1 (try --help)"
            exit 2
            ;;
        esac
    done

    if [ "$IT_MODE" = "ssh" ] && [ -z "$IT_SSH_DEST" ]; then
        it_err "Provide --host <user@host> or --local. See --help."
        exit 2
    fi
    [[ -z "$RIG_NAME" || "$RIG_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || {
        it_err "--rig-name contains unsupported characters: $RIG_NAME"
        exit 2
    }
    [[ -z "$RIGFORGE_BOOTSTRAP_VERSION" || "$RIGFORGE_BOOTSTRAP_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        it_err "--rigforge-bootstrap-version must be a vX.Y.Z tag."
        exit 2
    }
    if [ -n "$RIGFORGE_BOOTSTRAP_VERSION" ] && [ -z "$RIG_NAME" ]; then
        it_err "--rigforge-bootstrap-version requires --rig-name."
        exit 2
    fi
}
