# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"

echo "== black-box: unchanged apply announces connections and converges local mining =="
build_val_sandbox
seed_env
printf '{"monero":{"wallet_address":"%s","node_username":"u","node_password":"p"},"tari":{"wallet_address":"%s"},"p2pool":{"stratum_password":"fixture.pool-pass"},"dashboard":{"secure":false,"host":"fixture-box"}}\n' "$WALLET" "$VALID_TARI" >"$V/config.json"
ca_out="$(cd "$V" && PATH="$V/bin:$PATH" DOCKER_LOG="$V/docker.log" ./pithead apply -y 2>&1)"
assert_rc "initial apply succeeds" "$?" 0
ca_env="$(cat "$V/.env")"

# Keep apply's real render/diff/lock path; replace only the miner runner with a call recorder.
# This isolates the missing call from whether this test host has an appliance miner installed.
ca_apply() {
    provision_local_miner() { printf '%s\n' "$(config_bool '.local_miner.enabled' false)" >>"$PWD/miner-calls"; }
    apply -y
}
export -f ca_apply
for ca_enabled in true false; do
    jq --argjson enabled "$ca_enabled" '.local_miner.enabled = $enabled' "$V/config.json" >"$V/config.next"
    mv "$V/config.next" "$V/config.json"
    : >"$V/docker.log"
    ca_out="$(PATH="$V/bin:$PATH" DOCKER_LOG="$V/docker.log" run_sourced_e "$V" ca_apply 2>&1)"
    assert_rc "local-miner-only apply ($ca_enabled) succeeds" "$?" 0
    assert_contains "local-miner-only apply ($ca_enabled) takes unchanged path" "$ca_out" "No configuration changes detected"
    assert_contains "local-miner-only apply ($ca_enabled) announces LAN pool" "$ca_out" "Pool URL: fixture-box:3333"
    assert_contains "local-miner-only apply ($ca_enabled) announces password" "$ca_out" "Stratum password: fixture.pool-pass"
    assert_eq "local-miner-only apply ($ca_enabled) calls provisioning" "$(tail -n 1 "$V/miner-calls" 2>/dev/null)" "$ca_enabled"
    assert_eq "local-miner-only apply ($ca_enabled) preserves rendered env" "$(cat "$V/.env")" "$ca_env"
    assert_not_contains "local-miner-only apply ($ca_enabled) avoids container recreate" "$(cat "$V/docker.log")" "compose up"
done
ca_out="$(cd "$V" && PATH="$V/bin:$PATH" DOCKER_LOG="$V/docker.log" ./pithead apply -y 2>&1)"
assert_contains "no-change apply announces LAN pool with miner off" "$ca_out" "Pool URL: fixture-box:3333"
assert_contains "no-change apply announces password with miner off" "$ca_out" "Stratum password: fixture.pool-pass"

echo "== unit: coordinator connection details respect bind, port, authentication and TLS =="
CA="$SANDBOX/connection-announce"
mkdir -p "$CA"
printf '{"local_miner":{"enabled":true}}\n' >"$CA/config.json"
printf 'HOST_IP=fixture-box\nSTRATUM_BIND=0.0.0.0\nSTRATUM_PORT=4444\nPROXY_STRATUM_PASSWORD=fixture.pool-pass\n' >"$CA/.env"
ca_out="$(run_sourced_e "$CA" announce_dashboard_url 2>&1)"
assert_contains "wildcard bind advertises host and custom port" "$ca_out" "Pool URL: fixture-box:4444"
assert_contains "local miner block remains present" "$ca_out" "Local miner opt-in is ON"
assert_contains "local miner retains loopback connection" "$ca_out" "127.0.0.1:4444"
printf 'HOST_IP=fixture-box\nSTRATUM_BIND=192.0.2.10\nSTRATUM_PORT=4444\nPROXY_STRATUM_PASSWORD=\n' >"$CA/.env"
ca_out="$(run_sourced_e "$CA" announce_dashboard_url 2>&1)"
assert_contains "specific bind advertises its address" "$ca_out" "Pool URL: 192.0.2.10:4444"
assert_contains "no password is stated explicitly" "$ca_out" "Stratum password: none set"
printf 'HOST_IP=fixture-box\nSTRATUM_BIND=127.0.0.1\nPROXY_STRATUM_PASSWORD=\n' >"$CA/.env"
ca_out="$(run_sourced_e "$CA" announce_dashboard_url 2>&1)"
assert_contains "loopback bind does not claim LAN reachability" "$ca_out" "Pool URL: 127.0.0.1:3333"
assert_contains "loopback bind explains access restriction" "$ca_out" "local connections only"
mkdir -p "$CA/tls"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CA/tls/key.pem" -out "$CA/tls/cert.pem" -days 1 -subj /CN=fixture >/dev/null 2>&1
printf 'HOST_IP=fixture-box\nSTRATUM_BIND=0.0.0.0\nPROXY_STRATUM_PASSWORD=\nPROXY_STRATUM_TLS=true\nPROXY_TLS_DIR=%s\n' "$CA/tls" >"$CA/.env"
ca_fp="$(openssl x509 -in "$CA/tls/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
ca_out="$(run_sourced_e "$CA" announce_dashboard_url 2>&1)"
assert_contains "connection details include actual TLS fingerprint" "$ca_out" "$ca_fp"

echo "== black-box: setup announces connections when start is declined =="
CAS="$SANDBOX/connection-setup"
mkdir -p "$CAS/build/tari" "$CAS/dashboard"
cp "$STACK" "$CAS/pithead"
cp "$ROOT/build/tari/config.toml.template" "$CAS/build/tari/"
: >"$CAS/dashboard/Dockerfile"
make_stubs "$CAS/bin"
cp "$V/config.json" "$CAS/config.json"
ca_out="$(cd "$CAS" && printf 'n\n' | PATH="$CAS/bin:$PATH" DOCKER_LOG=/dev/null ./pithead setup --skip-deps --skip-optimize 2>&1)"
assert_rc "setup with start declined succeeds" "$?" 0
assert_contains "setup with start declined announces pool" "$ca_out" "Pool URL: fixture-box:3333"
assert_contains "setup with start declined announces password" "$ca_out" "Stratum password: fixture.pool-pass"
ca_setup_reboot() {
    is_deployed() { return 1; }
    # shellcheck disable=SC2034 # setup consumes this global from the sourced CLI.
    optimize_kernel() { REBOOT_REQUIRED=true; }
    # shellcheck disable=SC2034 # check_prerequisites consumes this global from the sourced CLI.
    SKIP_DEPS=1
    setup
}
export -f ca_setup_reboot
ca_out="$(PATH="$CAS/bin:$PATH" DOCKER_LOG=/dev/null run_sourced_e "$CAS" ca_setup_reboot 2>&1)"
assert_rc "setup requiring reboot succeeds" "$?" 0
assert_contains "setup requiring reboot prints reboot notice" "$ca_out" "System optimization requires a reboot"
assert_contains "setup requiring reboot announces pool" "$ca_out" "Pool URL: fixture-box:3333"
assert_contains "setup requiring reboot announces password" "$ca_out" "Stratum password: fixture.pool-pass"
ca_out="$(cd "$V" && PATH="$V/bin:$PATH" DOCKER_LOG=/dev/null ./pithead up 2>&1)"
assert_rc "up succeeds" "$?" 0
assert_contains "up announces pool" "$ca_out" "Pool URL: fixture-box:3333"
assert_contains "up announces password" "$ca_out" "Stratum password: fixture.pool-pass"
unset CA CAS ca_out ca_enabled ca_env ca_fp
unset -f ca_apply ca_setup_reboot
