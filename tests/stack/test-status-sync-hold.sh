# shellcheck shell=bash
# shellcheck disable=SC2317  # stubs are called by stack_status in the sourced subshell
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: status distinguishes an optional Tari loading row from a global sync hold (#3351) =="

status_sync_case() { # <tari-required> <global-syncing> [miner state: "exited none" | "running healthy"] [curl: ok | down]
    local required="$1" syncing="$2" miner="${3:-exited none}" api="${4:-ok}"
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        env_get() {
            case "$1" in
            COMPOSE_PROFILES) printf '%s' 'local_node,local_tari' ;;
            TARI_REQUIRED) printf '%s' "$required" ;;
            *) return 1 ;;
            esac
        }
        docker() {
            [ -z "${STATUS_CALL_LOG:-}" ] || printf '%s\n' "$*" >>"$STATUS_CALL_LOG"
            case "$*" in
            "compose ps") return 0 ;;
            "compose config --services" | "compose ps -aq") tr ' ' '\n' <<<"${STATUS_SERVICES:-monerod tari p2pool xmrig-proxy}" ;;
            "inspect --format {{index "*)
                local id
                for id in "${@:4}"; do
                    case "$id" in
                    p2pool | xmrig-proxy) printf '%s %s\n' "$id" "$miner" ;;
                    *) printf '%s %s\n' "$id" 'running healthy' ;;
                    esac
                done
                ;;
            *)
                printf 'unexpected status docker call: %s\n' "$*" >&2
                return 97
                ;;
            esac
        }
        curl() {
            [ "$api" = ok ] || return 22
            printf '{"syncing":%s,"sync":{"monero":{"state":"done"},"tari":{"state":"loading"}}}\n' "$syncing"
        }
        os_migration_hold_active() { return 1; }
        monero_chain_status_line() { :; }
        tari_chain_status_line() { :; }
        print_clearnet_banner() { :; }
        announce_stratum_auth() { :; }
        announce_stratum_tls() { :; }
        stack_status 2>&1
    )
}

optional_out="$(status_sync_case false false)"
assert_not_contains "optional Tari status uses only recognized docker calls" \
    "$optional_out" "unexpected status docker call"
assert_not_contains "optional Tari loading does not label stopped miners as sync-held" \
    "$optional_out" "held until the required chains finish syncing"
assert_not_contains "optional Tari loading does not announce a global miner sync hold" \
    "$optional_out" "Chain sync in progress — the miner is held"
assert_contains "optional Tari loading still reports the stopped miner" "$optional_out" "p2pool"

required_out="$(status_sync_case true true)"
assert_not_contains "required-chain status uses only recognized docker calls" \
    "$required_out" "unexpected status docker call"
assert_contains "a real required-chain sync still explains the intentional hold" \
    "$required_out" "held until the required chains finish syncing"
assert_contains "a real required-chain sync announces global hold progress" \
    "$required_out" "Chain sync in progress — the miner is held"

healthy_out="$(status_sync_case false false 'running healthy')"
assert_not_contains "healthy running miners with optional Tari loading: no global sync hold" \
    "$healthy_out" "Chain sync in progress — the miner is held"

down_out="$(status_sync_case true true 'exited none' down)"
assert_contains "dashboard unreachable keeps the old held wording" \
    "$down_out" "held until the required chains finish syncing"

STATUS_CALL_LOG="$SANDBOX/status-calls.log"
: >"$STATUS_CALL_LOG"
status_sync_case false false >/dev/null
status_calls_four=$(grep -c '' "$STATUS_CALL_LOG")
: >"$STATUS_CALL_LOG"
STATUS_SERVICES="monerod tari p2pool xmrig-proxy tor caddy dashboard docker-proxy docker-control notify wallet-rpc tari-wallet" status_sync_case false false >/dev/null
assert_eq "status makes the same number of engine calls for 12 services as for 4 (#4458)" \
    "$(grep -c '' "$STATUS_CALL_LOG")" "$status_calls_four"
assert_eq "status makes 6 engine calls for a 4-service stack (#4458)" "$status_calls_four" 6
