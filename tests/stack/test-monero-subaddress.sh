# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${ROOT:?}" "${SANDBOX:?}"

echo "== Monero mining subaddress (#2484) =="

build_val_sandbox
seed_env
SUBADDRESS_TEST_HOST=$(sed -n 's/^HOST_IP=//p' "$V/.env")
jq -n --arg wallet "$VALID_PRIMARY" --arg subaddress "$VALID_SUBADDR" --arg host "$SUBADDRESS_TEST_HOST" \
    '{monero:{mode:"local",wallet_address:$wallet,subaddress:$subaddress},
      tari:{mode:"off"},p2pool:{pool:"mini"},xvb:{enabled:true,donor_id:"auto"},
      dashboard:{secure:true,host:$host}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "primary plus checksum-valid subaddress applies" "$?" "0"
assert_contains "subaddress renders to the environment" "$(cat "$V/.env")" "MONERO_SUBADDRESS=$VALID_SUBADDR"
assert_contains "XvB auto donor id stays tied to the primary" "$(cat "$V/.env")" "XVB_DONOR_ID=${VALID_PRIMARY:0:8}"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead doctor 2>&1)"
assert_contains "doctor accepts the primary and mining subaddress pair" "$out" "primary address and mining subaddress are valid"
jq '.monero.subaddress = ""' "$V/config.json" >"$V/config.next" && mv "$V/config.next" "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "clearing the optional subaddress applies" "$?" "0"
assert_not_contains "clearing the subaddress omits its environment row" "$(cat "$V/.env")" "MONERO_SUBADDRESS="

seed_env
jq -n --arg wallet "$VALID_PRIMARY" --arg host "$SUBADDRESS_TEST_HOST" \
    '{monero:{mode:"local",wallet_address:$wallet,subaddress:$wallet},
      tari:{mode:"off"},p2pool:{pool:"mini"},dashboard:{secure:true,host:$host}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "primary address in monero.subaddress is rejected" "$?" "1"
assert_contains "wrong subaddress type names the field" "$out" "monero.subaddress"
seed_env
jq -n --arg wallet "$VALID_PRIMARY" --arg host "$SUBADDRESS_TEST_HOST" \
    '{monero:{mode:"local",wallet_address:$wallet,subaddress:false},
      tari:{mode:"off"},p2pool:{pool:"mini"},dashboard:{secure:true,host:$host}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "non-string monero.subaddress is rejected" "$?" "1"
assert_contains "non-string error names the required type" "$out" "must be a string"

EPBIN="$SANDBOX/p2pool-subaddress-bin"
mkdir -p "$EPBIN"
printf '#!/usr/bin/env bash\nprintf '\''ARG=[%%s]\\n'\'' "$@"\n' >"$EPBIN/p2pool"
chmod +x "$EPBIN/p2pool"
out="$(PATH="$EPBIN:$PATH" MONERO_SUBADDRESS="$VALID_SUBADDR" P2POOL_FLAGS='' \
    bash "$ROOT/build/p2pool/entrypoint.sh" --wallet "$VALID_PRIMARY" 2>&1)"
assert_contains "P2Pool receives --subaddress" "$out" "ARG=[--subaddress]"
assert_contains "P2Pool receives the configured subaddress" "$out" "ARG=[$VALID_SUBADDR]"
assert_not_contains "launch log masks the subaddress" \
    "$(printf '%s\n' "$out" | sed -n 's/^\[p2pool-entrypoint\] launching: //p')" "$VALID_SUBADDR"
assert_not_contains "support-bundle redaction masks the subaddress" \
    "$(printf '%s\n' "p2pool --subaddress $VALID_SUBADDR" | run_sourced "$V" bundle_redact_log)" "$VALID_SUBADDR"
out="$(PATH="$EPBIN:$PATH" MONERO_SUBADDRESS='' P2POOL_FLAGS='' \
    bash "$ROOT/build/p2pool/entrypoint.sh" --wallet "$VALID_PRIMARY" 2>&1)"
assert_not_contains "empty subaddress adds no P2Pool flag" "$out" "ARG=[--subaddress]"

QSUB="$SANDBOX/quadlet-subaddress"
cp "$ROOT/os/quadlet/fixture.env" "$SANDBOX/subaddress.env"
printf 'MONERO_SUBADDRESS=rendered-subaddress\n' >>"$SANDBOX/subaddress.env"
run_sourced "$SANDBOX" render_quadlet_units "$SANDBOX/subaddress.env" "$QSUB" >/dev/null
assert_contains "Quadlet passes the optional subaddress to P2Pool" \
    "$(sed -n 's/^Environment=//p' "$QSUB/p2pool.container")" '"MONERO_SUBADDRESS=rendered-subaddress"'
assert_contains "Quadlet passes the optional subaddress to the dashboard" \
    "$(sed -n 's/^Environment=//p' "$QSUB/dashboard.container")" '"MONERO_SUBADDRESS=rendered-subaddress"'

compose_p2pool=$(awk '/^  p2pool:/{f=1;next} f&&/^  [a-z]/{f=0} f' "$ROOT/docker-compose.yml")
compose_dashboard=$(awk '/^  dashboard:/{f=1;next} f&&/^  [a-z]/{f=0} f' "$ROOT/docker-compose.yml")
assert_contains "Compose passes the optional subaddress to P2Pool" "$compose_p2pool" 'MONERO_SUBADDRESS=${MONERO_SUBADDRESS:-}'
assert_contains "Compose passes the optional subaddress to the dashboard" "$compose_dashboard" 'MONERO_SUBADDRESS=${MONERO_SUBADDRESS:-}'

change="$(run_sourced "$V" describe_change MONERO_SUBADDRESS '' "$VALID_SUBADDR")"
assert_contains "subaddress change is a payout redirect" "$change" $'DEST\t'
assert_contains "subaddress change names future rewards" "$change" "future mining rewards"

staged="$SANDBOX/subaddress-staged.json"
jq -n --arg wallet "$VALID_PRIMARY" --arg subaddress "$VALID_SUBADDR" \
    '{monero:{wallet_address:$wallet,subaddress:$subaddress}}' >"$staged"
approval="$(jq -n --arg suffix "${VALID_SUBADDR: -8}" '{payout_suffixes:{monero_subaddress:$suffix}}')"
porcelain=$(printf 'DEST\tMONERO_SUBADDRESS\tpayout changed')
out="$(run_sourced "$V" control_validate_approval "$staged" operator "$approval" "$porcelain" 2>&1)"
assert_rc "control approval accepts the exact subaddress suffix" "$?" "0"
approval="$(jq -n '{payout_suffixes:{monero_subaddress:"wrong"}}')"
out="$(run_sourced "$V" control_validate_approval "$staged" operator "$approval" "$porcelain" 2>&1)"
assert_rc "control approval rejects a wrong subaddress suffix" "$?" "1"
assert_contains "control refusal names the mining subaddress" "$out" "subaddress"
staged_without="$SANDBOX/subaddress-removed.json"
jq -n --arg wallet "$VALID_PRIMARY" '{monero:{wallet_address:$wallet,subaddress:""}}' >"$staged_without"
approval="$(jq -n --arg suffix "${VALID_PRIMARY: -8}" '{payout_suffixes:{monero_subaddress:$suffix}}')"
out="$(run_sourced "$V" control_validate_approval "$staged_without" operator "$approval" "$porcelain" 2>&1)"
assert_rc "removing the subaddress confirms the primary destination" "$?" "0"

subaddress_preview_suffix=$(
    SANDBOX="$SANDBOX/subaddress-control-fixture"
    export WALLET="$VALID_PRIMARY"
    ensure_control_fixture
    jq --arg subaddress "$VALID_SUBADDR" '.monero.subaddress = $subaddress' "$C/config.json" >"$C/config.next" && mv "$C/config.next" "$C/config.json"
    (cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
    jq '.monero.subaddress = ""' "$C/config.json" >"$C/cand.json"
    jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
    run_pending >/dev/null
    jq -r '.payout_confirmations.monero_subaddress' "$RESULTS/$UUID5.json"
)
assert_eq "dashboard preview confirms the primary suffix when removing the subaddress" \
    "$subaddress_preview_suffix" "${VALID_PRIMARY: -8}"

assert_contains "CLI wizard points advanced users at the optional field" \
    "$(run_sourced "$V" wizard_print_pointer)" "monero.subaddress"
