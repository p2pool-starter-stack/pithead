#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/os/coordinator-setup-again-leg.sh
source "$here/coordinator-setup-again-leg.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture_answers='{"monero":{"wallet_address":"fixture-monero","mode":"local","out_peers":12},"tari":{"wallet_address":"fixture-tari","mode":"local"},"p2pool":{"pool":"nano"}}'
state='{"stage":"setup","saved_role":{"role":"pithead"},"new_machine":false,"config":{"monero":{"wallet_address":"fixture-monero","mode":"local","out_peers":12,"node_password":""},"tari":{"wallet_address":"fixture-tari","mode":"local"},"p2pool":{"pool":"nano","stratum_password":""},"dashboard":{"auth":{"password":""}}}}'
coordinator_saved_state_valid "$state" "$fixture_answers"
for mutation in '.saved_role.role="rig"' '.saved_role.token="secret"' '.stage="handoff"' \
    '.new_machine=true' '.config.p2pool.pool="mini"' '.config.monero.node_password="secret"' \
    '.config.monero.view_key="secret"' '.config.tari.spend_public_key="secret"' \
    '.config.dashboard.auth.password="secret"' '.config.telegram.bot_token="secret"' '.config.monero.node_username="secret"' \
    '.config.healthchecks.ping_url="secret"' '.config.notifications.ntfy.url="secret"' \
    '.config.xvb.standby.source="secret"' '.config.monero.out_peers=48' '.config.p2pool.stratum_password="secret"'; do
    if coordinator_saved_state_valid "$(printf '%s' "$state" | jq "$mutation")" "$fixture_answers"; then
        printf 'accepted invalid saved state: %s\n' "$mutation" >&2
        exit 1
    fi
done
if coordinator_saved_state_valid '{}' "$fixture_answers" || coordinator_saved_state_valid 'unreadable' "$fixture_answers"; then
    exit 1
fi
echo 'coordinator prefill: safe answers accepted, 18 invalid states refused'

(
    # shellcheck source=tests/os/setup-again-leg.sh
    source "$here/setup-again-leg.sh"
    SERIAL="$work/serial" ip=fixture jar="" token=""
    printf 'pit-ABC123\n' >"$SERIAL"
    _wait_setup_page() { :; }
    ok() { printf '%s\n' "$*" >>"$work/session-log"; }
    bad() { return 1; }
    curl() {
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -c ]; then
                printf 'wizard_session\n' >"$2"
                return
            fi
            shift
        done
        return 1
    }
    _setup_again_session
    [ "$token" = pit-ABC123 ]
    ! grep -q pit-ABC123 "$work/session-log"
    rm -f "$jar"
)
(
    # shellcheck source=tests/os/provision-browser-submit.sh
    source "$here/provision-browser-submit.sh"
    curl() {
        case " $* " in
        *' --max-filesize 1048576 '*) printf '%s\n200' "$state" ;;
        *) return 22 ;;
        esac
    }
    sleep() { :; }
    wizard_state_poll fixture fixture '.'
    [ "$WIZ_STATE" = "$(printf '%s' "$state" | jq -c '.')" ]
)
echo 'coordinator transport: session token stays private and wizard state has a response cap'

ok() { printf 'ok:%s\n' "$*" >>"$work/trace"; }
bad() { printf 'bad:%s\n' "$*" >>"$work/trace"; }
sleep() { SECONDS=$((SECONDS + 601)); }
provisioning_settled() { [ "$scenario" != unsettled ]; }
provisioning_setup_failed() { return 1; }
_setup_again_boot() {
    printf 'boot\n' >>"$work/trace"
    [ "$scenario" != boot-failed ]
}
_setup_again_session() {
    jar=$(mktemp "$work/jar.XXXXXX")
    [ "$scenario" != session-failed ]
}
wizard_state_poll() {
    WIZ_STATE="$state"
    [ "$scenario" != prefill-failed ] || WIZ_STATE='{}'
}
_monerod_height() {
    if [ "$scenario" = height-regressed ] && [ "$(cat "$work/stage")" != baseline ]; then
        printf 1
    else
        printf 123
    fi
}
dashboard_curl() {
    local stage
    stage=$(cat "$work/stage")
    printf 'login:%s:%s:%s\n' "$stage" "$DASH_USER" "$DASH_PASS" >>"$work/auth"
    case "$scenario:$stage" in
    login-changed:keep | resubmit-login-failed:resubmit) return 1 ;;
    malformed-state:keep) printf '{}' ;;
    *) printf '{"services":{"tor":{}}}' ;;
    esac
}
_ssh() {
    local stage
    stage=$(cat "$work/stage")
    case "$*" in
    *'jq -Sc'*) printf '%s\n' "$fixture_answers" ;;
    *'jq -e'*)
        printf 'secret-baseline\n' >>"$work/trace"
        [ "$scenario" != secret-baseline-missing ]
        ;;
    *'sha256sum config.json'*)
        if [ "$scenario:$stage" = config-changed:keep ]; then printf changed; else printf original; fi
        ;;
    *'sha256sum /etc/machine-id'*)
        printf 'machine-key-hashes\n'
        if [ "$scenario:$stage" = identity-changed:keep ]; then
            printf '%056d.onion\n' 0 | tr 0 b
        elif [ "$scenario:$stage" = onion-changed:resubmit ]; then
            printf '%056d.onion\n' 0 | tr 0 c
        else
            printf '%056d.onion\n' 0 | tr 0 a
        fi
        ;;
    *'test "$(cat data/monero/'*) [ -f "$work/sentinels" ] && [ "$scenario" != chain-lost ] ;;
    *'printf coordinator-chain'*) touch "$work/sentinels" ;;
    'systemctl is-active --quiet pithead-setup-again'*)
        printf 'setup-complete\n' >>"$work/trace"
        [ "$scenario" != setup-not-settled ]
        ;;
    'test ! -e /data/pithead/data/firstboot/keep-role'*) [ "$scenario" != keep-marker-left ] ;;
    *'rm -f /data/pithead/data/monero/'*)
        rm -f "$work/sentinels"
        printf 'cleanup\n' >>"$work/trace"
        [ "$scenario" != cleanup-failed ]
        ;;
    *)
        printf 'unexpected-ssh\n' >>"$work/trace"
        return 1
        ;;
    esac
}
curl() {
    case "$*" in
    *'/keep-role'*)
        printf keep >"$work/stage"
        if [ "$scenario" = keep-refused ]; then printf 403; else printf 200; fi
        ;;
    *'/api/handoff'*)
        case " $* " in *' --max-filesize 1048576 '*) ;; *) return 22 ;; esac
        if [ "$scenario" = missing-handoff ]; then printf '{}'; else printf '{"username":"new-admin","password":"new-login"}'; fi
        ;;
    *'/handoff-ack'*)
        printf resubmit >"$work/stage"
        if [ "$scenario" = ack-refused ]; then printf 403; else printf 200; fi
        ;;
    *'/submit'*)
        if [ "$scenario" = submit-refused ]; then printf 400; else printf 200; fi
        ;;
    *) return 1 ;;
    esac
}
ip=fixture
for scenario in success boot-failed session-failed prefill-failed keep-refused login-changed \
    config-changed identity-changed chain-lost height-regressed malformed-state \
    submit-refused missing-handoff ack-refused resubmit-login-failed onion-changed unsettled \
    secret-baseline-missing setup-not-settled keep-marker-left cleanup-failed; do
    printf baseline >"$work/stage"
    : >"$work/trace"
    : >"$work/auth"
    rc=0
    phase_coordinator_setup_again admin original-login || rc=$?
    if [ "$scenario" = success ]; then
        [ "$rc" -eq 0 ]
        [ "$(grep -c '^ok:' "$work/trace")" -eq 5 ]
        [ "$(grep -c '^boot$' "$work/trace")" -eq 2 ]
        grep -qx 'login:keep:admin:original-login' "$work/auth"
        grep -qx 'login:resubmit:new-admin:new-login' "$work/auth"
        grep -qx secret-baseline "$work/trace"
        [ "$(grep -c '^setup-complete$' "$work/trace")" -eq 2 ]
        ! grep -q '^bad:' "$work/trace"
    else
        [ "$rc" -ne 0 ]
        grep -q '^bad:' "$work/trace"
    fi
    [ "$(tail -1 "$work/trace")" = cleanup ] || grep -q '^cleanup$' "$work/trace"
    [ -z "$(find "$work" -name 'jar.*' -print -quit)" ]
    ! grep -q '^unexpected-ssh$' "$work/trace"
    printf 'coordinator setup-again flow: %s PASS\n' "$scenario"
done
grep -Fq 'source "$SCRIPT_DIR/coordinator-setup-again-leg.sh"' "$here/phases/reset.sh"
python3 - "$here/phases/reset.sh" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
assert source.index('phase_coordinator_setup_again "$reset_user" "$reset_pass" || return') < source.index('if _phase_reset_config; then')
PY
echo 'coordinator setup-again: reset phase invokes the leg before destructive reset'

(
    # shellcheck disable=SC2034
    OS_RUN_SUITE=1 SCRIPT_DIR="$here" SERIAL="$work/reset-serial"
    # shellcheck source=tests/os/phases/reset.sh
    source "$here/phases/reset.sh"
    HARNESS_WALLET=fixture-monero HARNESS_TARI=fixture-tari
    printf 'pit-ABC123\n' >"$SERIAL"
    info() { :; }
    _build_image() { printf fixture-image; }
    _vm_boot_disk() { :; }
    _wait_ssh() { :; }
    _wait_setup_page() { :; }
    provisioning_settled() { :; }
    provisioning_state() { printf fixture-settled; }
    _ssh() {
        case "$*" in *'podman ps'*) printf 'dashboard\ncaddy\n' ;; esac
        return 0
    }
    phase_coordinator_setup_again() {
        [ "$1" = admin ] && [ "$2" = fixture-login ] || return 1
        touch "$work/reset-reached"
        return 1
    }
    curl() {
        case "$*" in
        *'/auth'*)
            while [ "$#" -gt 0 ]; do
                if [ "$1" = -c ]; then
                    printf 'wizard_session\n' >"$2"
                    return
                fi
                shift
            done
            return 1
            ;;
        *'/api/handoff'*)
            case " $* " in *' --max-filesize 1048576 '*) ;; *) return 22 ;; esac
            printf '{"username":"admin","password":"fixture-login"}'
            ;;
        *'/submit'*)
            case "$*" in *'tari_mode=local&pool=nano&stratum_password=true'*) printf 200 ;; *) return 1 ;; esac
            ;;
        *'/handoff-ack'*) printf 200 ;;
        *) return 1 ;;
        esac
    }
    phase_reset || :
    [ -f "$work/reset-reached" ]
)
echo 'coordinator reset fixture: capped initial handoff supplies the original login'
