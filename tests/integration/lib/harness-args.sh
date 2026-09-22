# shellcheck shell=bash
# --harness-arg: bench-ci#46 forwards a hand-picked run.sh phase selection this way. Allowlisted
# ONLY — never built into a shell string from the raw value (#2179) — and refused up front, before
# any bench work, exactly like the --scenario mode restriction next to its call site: --mode check
# runs nothing but --check, so a destructive addition here would join a run the mode promises never
# touches anything.
validate_harness_args() { # reads HARNESS_ARGS[]; sets HARNESS_PHASE_ARGS
    HARNESS_PHASE_ARGS=""
    ROTATE_FIXTURE_ATTESTATION=""
    ROTATE_FIXTURE_REQUIRED=0
    [ "${#HARNESS_ARGS[@]}" -eq 0 ] && return 0
    [ "$MODE" != "check" ] || die "--harness-arg is not supported with --mode check."
    local i=0 arg next
    while [ "$i" -lt "${#HARNESS_ARGS[@]}" ]; do
        arg="${HARNESS_ARGS[$i]}"
        case "$arg" in
        --rotate-onion)
            [ "${KEEP:-0}" != 1 ] || die "--rotate-onion cannot be combined with --keep; its isolated identity must be removed."
            ROTATE_FIXTURE_REQUIRED=1
            HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS $arg"
            i=$((i + 1))
            ;;
        --lifecycle | --fault-injection | --auth-fail-closed | --hardening | --subnet | --safety-backup | --rigforge | --rigforge-control | --xvb-routing-smoke)
            HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS $arg"
            i=$((i + 1))
            ;;
        --scenario)
            next="${HARNESS_ARGS[$((i + 1))]:-}"
            [[ "$next" =~ ^[a-z0-9-]+$ ]] || die "--harness-arg --scenario needs a name matching ^[a-z0-9-]+\$ as the NEXT --harness-arg (got '$next')."
            HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS --scenario $(quote_arg "$next")"
            i=$((i + 2))
            ;;
        *)
            die "--harness-arg does not accept '$arg' — allowed: --lifecycle, --fault-injection, --auth-fail-closed, --hardening, --rotate-onion, --subnet, --safety-backup, --rigforge, --rigforge-control, --xvb-routing-smoke, --scenario <name>."
            ;;
        esac
    done
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
        ./pithead render >/dev/null
        docker compose up -d tor >/dev/null
        docker compose restart tor >/dev/null
        profiles=\$(awk -F= '\$1 == \"COMPOSE_PROFILES\" { print substr(\$0, index(\$0, \"=\") + 1); count++ } END { if (count != 1) exit 1 }' .env)
        services='p2pool dashboard'
        case \",\$profiles,\" in *,local_node,*) services=\"\$services monero\" ;; esac
        case \",\$profiles,\" in *,local_tari,*) services=\"\$services tari\" ;; esac
        p2pool= dashboard= monero=placeholder tari=placeholder
        for svc in \$services; do
            elapsed=0
            until docker exec tor test -f \"/var/lib/tor/\$svc/hostname\"; do
                test \"\$elapsed\" -lt 60
                sleep 2
                elapsed=\$((elapsed + 2))
            done
            address=\$(docker exec tor cat \"/var/lib/tor/\$svc/hostname\")
            printf '%s\n' \"\$address\" | grep -Eq '^[a-z2-7]{56}\.onion\$'
            case \"\$svc\" in
                p2pool) p2pool=\"\$address\" ;;
                dashboard) dashboard=\"\$address\" ;;
                monero) monero=\"\$address\" ;;
                tari) tari=\"\$address\" ;;
            esac
        done
        export ROTATE_P2POOL=\"\$p2pool\" ROTATE_DASHBOARD=\"\$dashboard\" ROTATE_MONERO=\"\$monero\" ROTATE_TARI=\"\$tari\"
        umask 077
        trap 'rm -f .env.rotate-fixture' EXIT
        awk -F= '
            BEGIN {
                replacement[\"P2POOL_ONION_ADDRESS\"] = ENVIRON[\"ROTATE_P2POOL\"]
                replacement[\"MONERO_ONION_ADDRESS\"] = ENVIRON[\"ROTATE_MONERO\"]
                replacement[\"TARI_ONION_ADDRESS\"] = ENVIRON[\"ROTATE_TARI\"]
                replacement[\"DASHBOARD_ONION_ADDRESS\"] = ENVIRON[\"ROTATE_DASHBOARD\"]
            }
            \$1 in replacement { print \$1 \"=\" replacement[\$1]; seen[\$1]++; next }
            { print }
            END {
                if (seen[\"P2POOL_ONION_ADDRESS\"] != 1 ||
                    seen[\"MONERO_ONION_ADDRESS\"] != 1 ||
                    seen[\"TARI_ONION_ADDRESS\"] != 1 ||
                    seen[\"DASHBOARD_ONION_ADDRESS\"] != 1) exit 1
            }
        ' .env > .env.rotate-fixture
        chmod 600 .env.rotate-fixture
        mv .env.rotate-fixture .env
        trap - EXIT
        ./pithead render >/dev/null
    "
}

cleanup_rotate_onion_fixture() {
    [ -n "${ROTATE_FIXTURE_DIR:-}" ] || return 0
    local parent="$E2E_DIR/data"
    case "$ROTATE_FIXTURE_DIR" in "$parent"/rotate-onion-fixture.*) ;; *) return 1 ;; esac
    on_bench "
        set -e
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
        snapshot=$(quote_arg "$E2E_DIR/backups/rotate-onion-env-preserve")
        if test -e \"\$snapshot\" || test -L \"\$snapshot\"; then
            test -d $(quote_arg "$E2E_DIR/backups") && test ! -L $(quote_arg "$E2E_DIR/backups")
            test -f \"\$snapshot\" && test ! -L \"\$snapshot\"
            rm -f -- \"\$snapshot\"
        fi
        sudo -n test ! -L $(quote_arg "$ROTATE_FIXTURE_DIR")
        sudo -n rm -rf --one-file-system -- $(quote_arg "$ROTATE_FIXTURE_DIR")
        sudo -n rm -f -- $(quote_arg "$ROTATE_FIXTURE_DIR.attestation")
        sudo -n test ! -e $(quote_arg "$ROTATE_FIXTURE_DIR")
        sudo -n test ! -e $(quote_arg "$ROTATE_FIXTURE_DIR.attestation")
    " || return 1
    ROTATE_FIXTURE_DIR=""
}
