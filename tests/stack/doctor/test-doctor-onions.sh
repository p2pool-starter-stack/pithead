# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== black-box: doctor's onion report follows node mode (#103) =="
# A node running elsewhere has no hidden service to provision, so its placeholder address is the
# correct state — doctor must not send the operator back to `setup` over it. A LOCAL node with no
# address is still a real problem and must keep warning.
DOC="$SANDBOX/doctor-onion"
mkdir -p "$DOC/build/tari" "$DOC/dashboard"
: >"$DOC/dashboard/Dockerfile"
cp "$STACK" "$DOC/pithead"
cp "$ROOT/build/tari/config.toml.template" "$DOC/build/tari/"
make_stubs "$DOC/bin"
printf '{"monero":{"mode":"remote","wallet_address":"%s","remote":{"host":"10.0.0.8"}},"tari":{"mode":"remote","wallet_address":"'"$VALID_TARI"'","remote":{"host":"10.0.0.9"}}}\n' "$VALID_PRIMARY" >"$DOC/config.json"
doctor_onions() { # <COMPOSE_PROFILES> -> doctor's "Tor onion addresses" section
    {
        printf 'MONERO_ONION_ADDRESS=placeholder\nTARI_ONION_ADDRESS=placeholder\nP2POOL_ONION_ADDRESS=p2pa.onion\n'
        printf 'TARI_GRPC_ADDRESS=10.0.0.9:18142\nDEPLOYMENT_COMPLETED=true\nHOST_IP=box.lan\n'
        printf 'COMPOSE_PROFILES=%s\n' "$1"
    } >"$DOC/.env"
    (cd "$DOC" && PATH="$DOC/bin:$PATH" ./pithead doctor 2>&1 | sed -n '/Tor onion addresses/,/^$/p')
}
doc_remote="$(doctor_onions "")"
assert_contains "doctor: a remote Monero node's missing onion is expected, not a warning (#103)" "$doc_remote" "MONERO_ONION_ADDRESS not needed"
assert_contains "doctor: a remote Tari node's missing onion is expected, not a warning (#103)" "$doc_remote" "TARI_ONION_ADDRESS not needed"
assert_contains "doctor: P2Pool's onion is still reported either way (#103)" "$doc_remote" "P2POOL_ONION_ADDRESS set"
doc_local="$(doctor_onions "local_node,local_tari")"
assert_contains "doctor: a LOCAL Monero node with no onion still warns (#103)" "$doc_local" "MONERO_ONION_ADDRESS is not provisioned"
assert_contains "doctor: a LOCAL Tari node with no onion still warns (#103)" "$doc_local" "TARI_ONION_ADDRESS is not provisioned"

# #1770: appliance remedies differ by onion key. P2Pool blocks apply while its onion is missing;
# the other three are re-created by the next dashboard-triggered apply. Keep the host's CLI remedy
# pinned too: dr_warn_surface must not change its first argument.
doctor_missing_onions() { # <PITHEAD_APPLIANCE> [pithead path] -> all four missing-onion doctor rows
    cat >"$DOC/.env" <<EOF
MONERO_ONION_ADDRESS=placeholder
TARI_ONION_ADDRESS=placeholder
P2POOL_ONION_ADDRESS=placeholder
DASHBOARD_ONION_ENABLED=true
DASHBOARD_ONION_ADDRESS=placeholder
TARI_GRPC_ADDRESS=10.0.0.9:18142
DEPLOYMENT_COMPLETED=true
HOST_IP=box.lan
COMPOSE_PROFILES=local_node,local_tari
EOF
    (cd "$DOC" && PITHEAD_APPLIANCE="$1" PATH="$DOC/bin:$PATH" "${2:-./pithead}" doctor 2>&1 | sed -n '/Tor onion addresses/,/^$/p')
}
onion_message() { # <doctor-output> <key> -> warning text, without terminal formatting
    printf '%s\n' "$1" | sed -n "s/^.*\($2.*\)$/\1/p"
}
host_remedy_for() { # <key>
    if [ "$1" = DASHBOARD_ONION_ADDRESS ]; then
        printf "%s is not provisioned yet — re-run './pithead setup' or './pithead apply'." "$1"
    else
        printf "%s is not provisioned (value: 'placeholder') — re-run './pithead setup' to generate Tor hidden services." "$1"
    fi
}
host_remedies_match() { # <doctor-output>
    local key
    for key in MONERO_ONION_ADDRESS TARI_ONION_ADDRESS P2POOL_ONION_ADDRESS DASHBOARD_ONION_ADDRESS; do
        [ "$(onion_message "$1" "$key")" = "$(host_remedy_for "$key")" ] || return 1
    done
}
doc_host="$(doctor_missing_onions 0)"
for onion_key in MONERO_ONION_ADDRESS TARI_ONION_ADDRESS P2POOL_ONION_ADDRESS DASHBOARD_ONION_ADDRESS; do
    assert_eq "doctor: host keeps each onion key's exact CLI remedy (#1770)" \
        "$(onion_message "$doc_host" "$onion_key")" "$(host_remedy_for "$onion_key")"
done
host_remedies_match "$doc_host"
assert_rc "doctor: exact host-remedy guard accepts production wording (#1770)" "$?" "0"
sed 's/to generate Tor hidden services\./to generate Tor hidden services. MUTATION/' "$DOC/pithead" >"$DOC/pithead-host-remedy-mutant"
mutant_host="$(doctor_missing_onions 0 "$DOC/pithead-host-remedy-mutant")"
host_remedies_match "$mutant_host"
assert_rc "doctor: appended host-remedy text trips the exact guard (#1770)" "$?" "1"
doc_appliance="$(doctor_missing_onions 1)"
p2pool_row="$(onion_message "$doc_appliance" P2POOL_ONION_ADDRESS)"
assert_contains "doctor: appliance P2Pool onion says console access is required (#1770)" "$p2pool_row" "correcting this needs console access"
assert_not_contains "doctor: appliance P2Pool onion does not promise dashboard regeneration (#1770)" "$p2pool_row" "saving any change from the dashboard provisions it"
for onion_key in MONERO_ONION_ADDRESS TARI_ONION_ADDRESS DASHBOARD_ONION_ADDRESS; do
    onion_remedy="$(onion_message "$doc_appliance" "$onion_key")"
    assert_contains "doctor: each regenerable appliance onion names dashboard apply (#1770)" "$onion_remedy" "saving any change from the dashboard provisions it"
    assert_not_contains "doctor: no regenerable appliance onion requires console access (#1770)" "$onion_remedy" "correcting this needs console access"
done
unset DOC doc_remote doc_local doc_host mutant_host doc_appliance onion_key p2pool_row onion_remedy doctor_onions doctor_missing_onions onion_message host_remedy_for host_remedies_match
