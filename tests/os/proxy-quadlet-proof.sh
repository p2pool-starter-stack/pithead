#!/usr/bin/env bash
set -euo pipefail
cd /data/pithead
proof_dir=$(mktemp -d "${TMPDIR:-/run}/pithead-proxy-health.XXXXXX")
proof_name="proxy-health-proof-${proof_dir##*.}"
unit="/run/containers/systemd/$proof_name.container"
collision_rc=0
podman container exists "$proof_name" >/dev/null 2>&1 || collision_rc=$?
if [ -e "$unit" ] || [ "$collision_rc" -ne 1 ]; then
    rmdir "$proof_dir"
    exit 1
fi
cleanup() {
    local cleanup_rc=0 service_state exists_rc=0
    systemctl stop "$proof_name.service" >/dev/null 2>&1 || cleanup_rc=1
    rm -f "$unit" || cleanup_rc=1
    systemctl daemon-reload || cleanup_rc=1
    podman container exists "$proof_name" >/dev/null 2>&1 || exists_rc=$?
    case "$exists_rc" in
    0) podman rm -f "$proof_name" >/dev/null 2>&1 || cleanup_rc=1 ;;
    1) ;;
    *) cleanup_rc=1 ;;
    esac
    exists_rc=0
    podman container exists "$proof_name" >/dev/null 2>&1 || exists_rc=$?
    [ "$exists_rc" -eq 1 ] || cleanup_rc=1
    service_state=$(systemctl is-active "$proof_name.service" 2>/dev/null || true)
    case "$service_state" in
    inactive | failed | unknown) ;;
    *) cleanup_rc=1 ;;
    esac
    rm -rf "$proof_dir" || cleanup_rc=1
    if [ "$cleanup_rc" -ne 0 ]; then
        echo 'FAIL: native Quadlet proxy cleanup failed' >&2
        exit "$cleanup_rc"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$proof_dir"
grep -vE '^(QUADLET_HOST_CONFIG_DIR|QUADLET_CADDYFILE|QUADLET_ENGINE_SOCK|PROXY_STRATUM_TLS|PROXY_STRATUM_PASSWORD)=' .env >"$proof_dir/env"
printf '\nQUADLET_HOST_CONFIG_DIR=/data/pithead\nQUADLET_CADDYFILE=/data/pithead/Caddyfile\nQUADLET_ENGINE_SOCK=/run/podman/podman.sock\nPROXY_STRATUM_TLS=false\nPROXY_STRATUM_PASSWORD=\n' >>"$proof_dir/env"
./pithead render-quadlet --env "$proof_dir/env" --out "$proof_dir/units" >/dev/null
image_ref=$(sed -n 's/^Image=//p' "$proof_dir/units/xmrig-proxy.container")
image=$(podman image inspect "$image_ref" --format '{{.Id}}')
[ -n "$image" ]
printf %s "$UNIT_FILTER_B64" | base64 -d >"$proof_dir/unit.awk"
mkdir -p /run/containers/systemd
awk -v image="$image" -v name="$proof_name" -f "$proof_dir/unit.awk" \
    "$proof_dir/units/xmrig-proxy.container" >"$unit"
chmod 600 "$unit"
systemctl daemon-reload
timeout 180 systemctl start "$proof_name.service"
systemctl show "$proof_name.service" -p FragmentPath --value | grep -q '/generator'
[ "$(systemctl show "$proof_name.service" -p Type --value)" = notify ]
[ "$(systemctl show "$proof_name.service" -p TimeoutStartUSec --value)" = infinity ]
echo 'PASS: native Quadlet proxy uses healthy notification with unlimited startup'
[ "$(podman inspect "$proof_name" --format '{{.HostConfig.NetworkMode}}')" = none ]
[ -z "$(podman port "$proof_name")" ]
echo 'PASS: native Quadlet proxy has no network access or published ports'
podman exec "$proof_name" test -x /usr/local/bin/xmrig-proxy-healthcheck.sh
podman healthcheck run "$proof_name"
health=$(podman inspect "$proof_name" --format '{{.State.Health.Status}}')
[ "$health" = healthy ]
systemctl is-active --quiet "$proof_name.service"
echo 'PASS: native Quadlet proxy runs its real API health probe and reports healthy'
cleanup
trap - EXIT
echo 'PASS: native Quadlet proxy health proof complete'
