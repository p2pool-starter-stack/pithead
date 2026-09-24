# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Tari major-upgrade free-space precheck (#2636): `upgrade` refuses to start a Tari major that
# migrates the node database when the data volume lacks room for a second copy of data.mdb.
# Builds its own throwaway dirs under $SANDBOX; df and docker are stubs on PATH, and data.mdb is
# a sparse file, so a 100 GiB database costs no disk.

echo "== unit: tari_image_major (#2636) =="
assert_eq "ghcr v6 tag with digest → 6" "$(run_sourced "$SANDBOX" tari_image_major 'ghcr.io/tari-project/minotari_node:v6.0.1-pre.0-mainnet@sha256:23ce')" "6"
assert_eq "quay v5 tag with digest → 5" "$(run_sourced "$SANDBOX" tari_image_major 'quay.io/tarilabs/minotari_node:v5.3.1-mainnet@sha256:824f')" "5"
assert_eq "registry port is not read as the tag" "$(run_sourced "$SANDBOX" tari_image_major 'reg.lan:5000/minotari_node:v6.0.0-mainnet')" "6"
run_sourced "$SANDBOX" tari_image_major 'quay.io/tarilabs/minotari_node:latest-mainnet' >/dev/null
assert_rc "latest-mainnet has no major" "$?" "1"
run_sourced "$SANDBOX" tari_image_major 'reg.lan:5000/minotari_node' >/dev/null
assert_rc "an untagged reference has no major" "$?" "1"

TUS="$SANDBOX/tari-upgrade-space"
mkdir -p "$TUS/bin" "$TUS/tari/mainnet/data/base_node/db"
TUS_DB="$TUS/tari/mainnet/data/base_node/db/data.mdb"
truncate -s 100G "$TUS_DB"
printf 'TARI_DATA_DIR=%s\n' "$TUS/tari" >"$TUS/.env"
# docker: compose config answers with the tari service the new release starts (TUS_TO_IMG empty
# = tari not local); inspect answers with the old container's image (TUS_FROM_IMG empty = none).
cat >"$TUS/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose config --format json")
    if [ -n "${TUS_TO_IMG:-}" ]; then printf '{"services":{"tari":{"image":"%s"}}}\n' "$TUS_TO_IMG"
    else printf '{"services":{"p2pool":{"image":"x"}}}\n'; fi ;;
  "inspect --type container --format {{.Config.Image}} tari")
    [ -n "${TUS_FROM_IMG:-}" ] || { echo "Error: No such object: tari" >&2; exit 1; }
    printf '%s\n' "$TUS_FROM_IMG" ;;
esac
exit 0
EOF
cat >"$TUS/bin/df" <<'EOF'
#!/usr/bin/env bash
[ "${TUS_DF_FAIL:-0}" = 1 ] && exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/sdz1 999999999 1 %s 1%% /srv/chain\n' "$TUS_AVAIL_KB"
EOF
chmod +x "$TUS/bin/docker" "$TUS/bin/df"
TUS_V5='quay.io/tarilabs/minotari_node:v5.3.1-mainnet@sha256:824f'
TUS_V6='ghcr.io/tari-project/minotari_node:v6.0.1-pre.0-mainnet@sha256:23ce'
tus_run() { # <from-image> <to-image> <avail GiB>
    TUS_FROM_IMG="$1" TUS_TO_IMG="$2" TUS_AVAIL_KB=$(($3 * 1048576)) DOCKER_LOG="$TUS/docker.log" \
        PATH="$TUS/bin:$PATH" run_sourced "$TUS" tari_upgrade_space_precheck 2>&1
}

echo "== unit: tari_node_db_file / tari_upgrade_space_precheck (#2636) =="
assert_eq "finds data.mdb under the network dir" "$(run_sourced "$SANDBOX" tari_node_db_file "$TUS/tari")" "$TUS_DB"
out="$(tus_run "$TUS_V5" "$TUS_V6" 50)"
assert_rc "5 → 6 with 50 GiB free for a 100 GiB database refuses" "$?" "1"
assert_contains "the refusal names the volume" "$out" "on /srv/chain"
assert_contains "the refusal names the size needed (data.mdb + 5 GiB margin)" "$out" "about 105 GiB free"
assert_contains "the refusal names the size free" "$out" "and it has 50 GiB free"
assert_contains "the refusal names the Tari majors" "$out" "Tari 5 → 6"
out="$(tus_run "$TUS_V5" "$TUS_V6" 105)"
assert_rc "5 → 6 with room for the copy plus the margin proceeds" "$?" "0"
assert_eq "…and says nothing" "$out" ""
out="$(tus_run "$TUS_V5" "$TUS_V6" 104)"
assert_rc "5 → 6 inside the 5 GiB margin still refuses" "$?" "1"
out="$(tus_run "$TUS_V6" "$TUS_V6" 1)"
assert_rc "same major (no migration) proceeds on a full volume" "$?" "0"
assert_eq "…and says nothing" "$out" ""
out="$(tus_run "$TUS_V5" "" 1)"
assert_rc "tari not local in the new release proceeds" "$?" "0"
assert_eq "…and says nothing" "$out" ""
out="$(tus_run "" "$TUS_V6" 50)"
assert_rc "no tari container to read: a shortfall does not refuse" "$?" "0"
assert_contains "…but warns with the sizes" "$out" "Could not tell which Tari version last ran"
assert_contains "…naming the volume and the need" "$out" "about 105 GiB free on /srv/chain"
out="$(TUS_DF_FAIL=1 tus_run "$TUS_V5" "$TUS_V6" 1)"
assert_rc "free space unreadable: no refusal on a guess" "$?" "0"
assert_contains "…but says the check did not run" "$out" "was not checked"
# data.mdb belongs to uid 1000; an operator who can list the dir but not open the file still gets
# the check under pithead's real shell options (errexit, ERR trap), not an arithmetic abort.
if [ "$(id -u)" = "0" ]; then
    echo "SKIP: unreadable data.mdb — root reads a mode-000 file, so this case proves nothing as root"
else
    chmod 000 "$TUS_DB"
    out="$(TUS_FROM_IMG="$TUS_V5" TUS_TO_IMG="$TUS_V6" TUS_AVAIL_KB=$((50 * 1048576)) \
        PATH="$TUS/bin:$PATH" run_sourced_e "$TUS" tari_upgrade_space_precheck 2>&1)"
    assert_rc "an unreadable data.mdb is still measured, and refuses" "$?" "1"
    assert_contains "…with the check's own message" "$out" "about 105 GiB free on /srv/chain"
    chmod 644 "$TUS_DB"
fi
mv "$TUS_DB" "$TUS/data.mdb.aside"
: >"$TUS/docker.log"
out="$(tus_run "$TUS_V5" "$TUS_V6" 1)"
assert_rc "no Tari database proceeds" "$?" "0"
assert_eq "…without asking docker anything" "$(cat "$TUS/docker.log")" ""
mv "$TUS/data.mdb.aside" "$TUS_DB"

echo "== black-box: upgrade refuses a Tari major migration before recreating anything (#2636) =="
U2="$SANDBOX/upgrade-tari-space"
mkdir -p "$U2/build/tari" "$U2/dashboard" "$U2/data/monero" "$U2/data/tari/mainnet/data/base_node/db" "$U2/data/p2pool/stats" "$U2/data/tor" "$U2/data/dashboard"
: >"$U2/dashboard/Dockerfile"
cp "$STACK" "$U2/pithead"
make_stubs "$U2/stub"
mkdir -p "$U2/bin"
# The shared stub answers everything else upgrade asks docker; this one adds the two Tari reads.
cat >"$U2/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "compose config --format json"|"inspect --type container --format {{.Config.Image}} tari") exec "$TUS/bin/docker" "\$@" ;;
esac
exec "$U2/stub/docker" "\$@"
EOF
cp "$TUS/bin/df" "$U2/stub/sudo" "$U2/bin/"
chmod +x "$U2/bin/docker"
cp "$ROOT/build/tari/config.toml.template" "$U2/build/tari/"
truncate -s 100G "$U2/data/tari/mainnet/data/base_node/db/data.mdb"
cat >"$U2/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$U2/config.json"
U2L="$U2/docker.log"
: >"$U2L"
out="$(cd "$U2" && TUS_FROM_IMG="$TUS_V5" TUS_TO_IMG="$TUS_V6" TUS_AVAIL_KB=$((50 * 1048576)) DOCKER_LOG="$U2L" PATH="$U2/bin:$PATH" ./pithead upgrade 2>&1)"
assert_rc "upgrade exits 1 on a volume too small for the migration" "$?" "1"
assert_contains "upgrade prints the refusal" "$out" "Refusing the upgrade: Tari 5 → 6"
assert_not_contains "no container was recreated" "$(cat "$U2L")" "compose up"
: >"$U2L"
out="$(cd "$U2" && TUS_FROM_IMG="$TUS_V5" TUS_TO_IMG="$TUS_V6" TUS_AVAIL_KB=$((200 * 1048576)) DOCKER_LOG="$U2L" PATH="$U2/bin:$PATH" ./pithead upgrade 2>&1)"
assert_rc "upgrade with room for the migration exits 0" "$?" "0"
assert_contains "…and recreates the containers" "$(cat "$U2L")" "compose up --pull never -d --build"
