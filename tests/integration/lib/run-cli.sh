# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
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
            if ! valid_remote_host "${2:-}"; then
                it_err "--remote-monero-host contains unsupported characters. Use a hostname or IPv4 address."
                exit 2
            fi
            case "${2:-}" in
            *:*)
                it_err "--remote-monero-host takes a BARE host or IP, not host:port — pithead renders the port separately (--remote-monero-rpc-port)."
                exit 2
                ;;
            esac
            REMOTE_MONERO_HOST="$2"
            shift 2
            ;;
        --remote-monero-rpc-port | --remote-monero-zmq-port)
            if ! valid_tcp_port "${2:-}"; then
                it_err "$1 takes a TCP port 1-65535."
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
            if ! valid_remote_host "${2:-}"; then
                it_err "--remote-tari-host contains unsupported characters. Use a bare hostname or IPv4 address."
                exit 2
            fi
            case "$2" in
            *:*)
                it_err "--remote-tari-host takes a bare host or IPv4 address; Pithead renders tari.remote.grpc_port separately."
                exit 2
                ;;
            esac
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
        --reset-dashboard)
            RUN_RESET_DASHBOARD=1
            shift
            ;;
        --fault-injection)
            RUN_FAULTS=1
            shift
            ;;
        --image-upgrade)
            [ "$#" -ge 3 ] || {
                it_err "--image-upgrade requires <old-sha> <new-sha>."
                exit 2
            }
            RUN_IMAGE_UPGRADE=1
            IMAGE_UPGRADE_FROM_SHA="${2:-}"
            IMAGE_UPGRADE_TO_SHA="${3:-}"
            shift 3
            ;;
        --candidate-bundle)
            [ "$#" -ge 4 ] || {
                it_err "--candidate-bundle requires <tar.gz> <signature> <trusted-cosign.pub>."
                exit 2
            }
            CANDIDATE_BUNDLE="$2"
            CANDIDATE_SIGNATURE="$3"
            TRUSTED_COSIGN_PUB="$4"
            shift 4
            ;;
        --candidate-image-key)
            [ "$#" -ge 2 ] || {
                it_err "--candidate-image-key requires <trusted-cosign.pub>."
                exit 2
            }
            TRUSTED_IMAGE_COSIGN_PUB="$2"
            shift 2
            ;;
        --xvb-routing-smoke)
            RUN_XVB_ROUTING=1
            shift
            ;;
        --alert-egress)
            RUN_ALERT_EGRESS=1
            shift
            ;;
        --mergemine-submit)
            RUN_MERGEMINE_SUBMIT=1
            shift
            ;;
        --tari-stranded)
            RUN_TARI_STRANDED=1
            shift
            ;;
        --monero-stranded)
            RUN_MONERO_STRANDED=1
            shift
            ;;
        --mergemine-localnet)
            RUN_MERGEMINE_LOCALNET=1
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
        --rotate-onion)
            RUN_ROTATE_ONION=1
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
        --rotate-secrets)
            RUN_ROTATE_SECRETS=1
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
    if [ "$RUN_IMAGE_UPGRADE" = "1" ]; then
        valid_full_sha "$IMAGE_UPGRADE_FROM_SHA" && valid_full_sha "$IMAGE_UPGRADE_TO_SHA" || {
            it_err "--image-upgrade requires two lowercase 40-hex Pithead commits."
            exit 2
        }
        [ "$SAFETY_BACKUP" = "1" ] || {
            it_err "--image-upgrade requires --safety-backup."
            exit 2
        }
        [ "$IMAGE_UPGRADE_FROM_SHA" != "$IMAGE_UPGRADE_TO_SHA" ] || {
            it_err "--image-upgrade old and new commits must differ."
            exit 2
        }
    fi
    if [ "$RUN_RESET_DASHBOARD" = "1" ] && [ "$SAFETY_BACKUP" != "1" ]; then
        it_err "--reset-dashboard requires --safety-backup."
        exit 2
    fi
    if [ "$RUN_ROTATE_SECRETS" = "1" ] && [ "$SAFETY_BACKUP" != "1" ]; then
        it_err "--rotate-secrets requires --safety-backup — its archive is this phase's own restore anchor."
        exit 2
    fi
    validate_live_gate_args
    # Both gates read mining as their success signal, so silencing those assertions would leave
    # them asserting nothing that matters.
    if [ "$SKIP_MINING_ASSERTS" = "1" ] && { [ "$RUN_IMAGE_UPGRADE" = "1" ] || [ "$RUN_XVB_ROUTING" = "1" ]; }; then
        it_err "--image-upgrade and --xvb-routing-smoke require binding mining assertions; remove --no-mining-asserts."
        exit 2
    fi
}
