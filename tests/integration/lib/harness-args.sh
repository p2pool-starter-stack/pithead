# shellcheck shell=bash
# --harness-arg: bench-ci#46 forwards a hand-picked run.sh phase selection this way. Allowlisted
# ONLY — never built into a shell string from the raw value (#2179) — and refused up front, before
# any bench work, exactly like the --scenario mode restriction next to its call site: --mode check
# runs nothing but --check, so a destructive addition here would join a run the mode promises never
# touches anything.
validate_harness_args() { # reads HARNESS_ARGS[]; sets HARNESS_PHASE_ARGS, HARNESS_SCENARIO_ARGS, TARGETED_SCENARIO_ARGS
    HARNESS_PHASE_ARGS=""
    unset TARGETED_SCENARIO_ARGS
    ROTATE_FIXTURE_ATTESTATION=""
    ROTATE_FIXTURE_REQUIRED=0
    HARNESS_SCENARIO_ARGS=""
    [ "${#HARNESS_ARGS[@]}" -eq 0 ] && return 0
    [ "$MODE" != "check" ] || die "--harness-arg is not supported with --mode check."
    local i=0 arg next
    while [ "$i" -lt "${#HARNESS_ARGS[@]}" ]; do
        arg="${HARNESS_ARGS[$i]}"
        case "$arg" in
        --lifecycle | --reset-dashboard | --fault-injection | --auth-fail-closed | --hardening | --rotate-onion | --subnet | --safety-backup | --rigforge | --rigforge-control | --xvb-routing-smoke | --rotate-secrets | --alert-egress | --mergemine-submit | --mergemine-localnet | --tari-stranded | --monero-stranded | --sweep)
            HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS $arg"
            if [ "$arg" = --rotate-onion ]; then
                [ "${KEEP:-0}" != 1 ] || die "--rotate-onion cannot be combined with --keep; its isolated identity must be removed."
                ROTATE_FIXTURE_REQUIRED=1
            fi
            i=$((i + 1))
            ;;
        --scenario)
            next="${HARNESS_ARGS[$((i + 1))]:-}"
            [[ "$next" =~ ^[a-z0-9-]+$ ]] || die "--harness-arg --scenario needs a name matching ^[a-z0-9-]+\$ as the NEXT --harness-arg (got '$next')."
            HARNESS_SCENARIO_ARGS="$HARNESS_SCENARIO_ARGS --scenario $(quote_arg "$next")"
            i=$((i + 2))
            ;;
        *)
            die "--harness-arg does not accept '$arg' — allowed: --lifecycle, --reset-dashboard, --fault-injection, --auth-fail-closed, --hardening, --rotate-onion, --subnet, --safety-backup, --rigforge, --rigforge-control, --xvb-routing-smoke, --rotate-secrets, --alert-egress, --mergemine-submit, --mergemine-localnet, --tari-stranded, --monero-stranded, --sweep, --scenario <name>."
            ;;
        esac
    done
    # --sweep is not a run.sh flag: the sweep is what run.sh does when no scenario is pinned.
    case " $HARNESS_PHASE_ARGS " in
    *" --sweep "*)
        [ -z "${SCENARIO:-}$HARNESS_SCENARIO_ARGS" ] || die "--harness-arg --sweep runs every scenario; it cannot be combined with a scenario."
        HARNESS_PHASE_ARGS="${HARNESS_PHASE_ARGS// --sweep/}"
        case " $HARNESS_PHASE_ARGS " in *" --safety-backup "*) ;; *) HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS --safety-backup" ;; esac
        # shellcheck disable=SC2034 # consumed by e2e.sh:run_harness
        TARGETED_SCENARIO_ARGS=""
        ;;
    esac
}

prepare_rotate_onion_fixture() {
    [ "${ROTATE_FIXTURE_REQUIRED:-0}" = 1 ] || return 0
    local parent="$E2E_DIR/data" fixture
    fixture="$(on_bench "set -e; mkdir -p $(quote_arg "$parent"); test -d $(quote_arg "$parent") && test ! -L $(quote_arg "$parent") && test \"\$(readlink -f -- $(quote_arg "$parent"))\" = $(quote_arg "$parent"); mktemp -d $(quote_arg "$parent/rotate-onion-fixture.XXXXXX")")" || return 1
    case "$fixture" in "$parent"/rotate-onion-fixture.*) ;; *) return 1 ;; esac
    ROTATE_FIXTURE_DIR="$fixture"
    on_bench "
        set -e
        cd $(quote_arg "$E2E_DIR")
        case $(quote_arg "$fixture") in $(quote_arg "$parent/rotate-onion-fixture.")*) ;; *) exit 1 ;; esac
        umask 077
        trap 'rm -f config.json.rotate-fixture .env.rotate-fixture' EXIT
        jq --arg d $(quote_arg "$fixture") '.dashboard.onion.enabled = true | .dashboard.onion.client_auth = true | .tor.data_dir = \$d' config.json > config.json.rotate-fixture
        chmod 600 config.json.rotate-fixture
        mv config.json.rotate-fixture config.json
        awk -F= '
            \$1 == \"P2POOL_ONION_ADDRESS\" ||
            \$1 == \"MONERO_ONION_ADDRESS\" ||
            \$1 == \"TARI_ONION_ADDRESS\" ||
            \$1 == \"DASHBOARD_ONION_ADDRESS\" ||
            \$1 == \"DASHBOARD_ONION_CLIENT_PUBKEY\" ||
            \$1 == \"DASHBOARD_ONION_CLIENT_PRIVKEY\" {
                print \$1 \"=placeholder\"; seen[\$1]++; next
            }
            { print }
            END {
                if (seen[\"P2POOL_ONION_ADDRESS\"] != 1 ||
                    seen[\"MONERO_ONION_ADDRESS\"] != 1 ||
                    seen[\"TARI_ONION_ADDRESS\"] != 1 ||
                    seen[\"DASHBOARD_ONION_ADDRESS\"] != 1 ||
                    seen[\"DASHBOARD_ONION_CLIENT_PUBKEY\"] != 1 ||
                    seen[\"DASHBOARD_ONION_CLIENT_PRIVKEY\"] != 1) exit 1
            }
        ' .env > .env.rotate-fixture
        chmod 600 .env.rotate-fixture
        mv .env.rotate-fixture .env
        printf '%s\n' $(quote_arg "$fixture") | sudo -n tee $(quote_arg "$fixture.attestation") >/dev/null
        sudo -n chown root:root $(quote_arg "$fixture.attestation")
        sudo -n chmod 600 $(quote_arg "$fixture.attestation")
        trap - EXIT
    " || return 1
    # shellcheck disable=SC2034 # consumed by e2e.sh:run_harness
    ROTATE_FIXTURE_ATTESTATION="$fixture"
}

bootstrap_rotate_onion_fixture() {
    [ -n "$ROTATE_FIXTURE_DIR" ] || return 0
    on_bench "
        set -e
        cd $(quote_arg "$E2E_DIR")
        PITHEAD_STEAL_CONTROL_UNITS=1 ./pithead render >/dev/null
        ./pithead rotate-dashboard-onion -y >/dev/null
    "
}

cleanup_rotate_onion_fixture() {
    [ -n "${ROTATE_FIXTURE_DIR:-}" ] || return 0
    local parent="$E2E_DIR/data"
    case "$ROTATE_FIXTURE_DIR" in "$parent"/rotate-onion-fixture.*) ;; *) return 1 ;; esac
    on_bench "
        set -e
        recovery=$(quote_arg "$E2E_DIR/backups/rotate-onion-identity-preserve")
        snapshot=$(quote_arg "$E2E_DIR/backups/rotate-onion-env-preserve")
        sudo -n test ! -e \"\$recovery\" && sudo -n test ! -L \"\$recovery\" &&
            test ! -e \"\$snapshot\" && test ! -L \"\$snapshot\" || exit 1
        cids=\$(docker ps -aq) || exit 1
        for cid in \$cids; do
            mounts=\$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' \"\$cid\") || exit 1
            while IFS= read -r source; do
                test -n \"\$source\" || continue
                test \"\$source\" != / || exit 1
                test \"\$source\" != $(quote_arg "$ROTATE_FIXTURE_DIR") || exit 1
                case \"\$source/\" in $(quote_arg "$ROTATE_FIXTURE_DIR/")*) exit 1 ;; esac
                case $(quote_arg "$ROTATE_FIXTURE_DIR/") in \"\$source/\"*) exit 1 ;; esac
            done <<EOF
\$mounts
EOF
        done
        sudo -n test ! -L $(quote_arg "$ROTATE_FIXTURE_DIR")
        sudo -n rm -rf --one-file-system -- $(quote_arg "$ROTATE_FIXTURE_DIR")
        sudo -n rm -f -- $(quote_arg "$ROTATE_FIXTURE_DIR.attestation")
        sudo -n test ! -e $(quote_arg "$ROTATE_FIXTURE_DIR")
        sudo -n test ! -e $(quote_arg "$ROTATE_FIXTURE_DIR.attestation")
    " || return 1
    ROTATE_FIXTURE_DIR=""
}
