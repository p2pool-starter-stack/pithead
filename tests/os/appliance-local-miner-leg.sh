#!/usr/bin/env bash
# Guest-side regression: a local_miner-only apply must stop/start the real miner without reboot.
set -Eeuo pipefail
umask 077
cd /data/pithead
fixture=$(mktemp -d "${TMPDIR:?}/local-miner-apply.XXXXXX")
cp config.json "$fixture/config.json"
restored_miner_matches() {
    if [ "$(jq -r '.local_miner.enabled // false' config.json)" = true ]; then
        systemctl is-active --quiet xmrig.service
        local pid
        pid=$(systemctl show xmrig.service -p MainPID --value)
        [ "$pid" -gt 0 ] && kill -0 "$pid"
    else
        ! systemctl is-active --quiet xmrig.service &&
            [ "$(systemctl show xmrig.service -p MainPID --value)" = 0 ]
    fi
}
cleanup() {
    local rc=$?
    trap - EXIT
    if cp "$fixture/config.json" config.json && ./pithead apply -y >"$fixture/restore.log" 2>&1 && restored_miner_matches; then
        printf '%s\n' 'local-miner: original configuration restored'
        rm -rf -- "$fixture"
    else
        printf '%s\n' 'local-miner: original configuration restore failed'
        rc=1
    fi
    exit "$rc"
}
report_failure() {
    local rc=$? line=$1 cmd=$2
    printf 'local-miner: step failed at line %s (rc=%s): %s\n' "$line" "$rc" "$cmd"
    printf 'local-miner: state xmrig=%s mainpid=%s rigforge_config=%s\n' \
        "$(systemctl is-active xmrig.service 2>&1 || true)" \
        "$(systemctl show xmrig.service -p MainPID --value 2>&1 || true)" \
        "$([ -f /data/rigforge/config.json ] && echo present || echo absent)"
    printf 'local-miner: rebooted=%s env_changed=%s\n' \
        "$([ "$(cat /proc/sys/kernel/random/boot_id)" = "${boot:-}" ] && echo no || echo yes)" \
        "$([ "$(sha256sum .env)" = "${env_before:-}" ] && echo no || echo yes)"
    if [ -f "$fixture/apply.log" ]; then
        sed -e 's/\x1b\[[0-9;]*m//g' "$fixture/apply.log" | grep -E '^\[(ERROR|WARNING)\]|No configuration changes' | tail -n 8 | cut -c1-200 | sed 's/^/local-miner: apply: /' || true
    fi
}
trap 'report_failure "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT
[ "$(jq -r '.local_miner.enabled' config.json)" = true ]
restored_miner_matches
boot=$(cat /proc/sys/kernel/random/boot_id)
env_before=$(sha256sum .env)
for enabled in false true; do
    jq --argjson enabled "$enabled" '.local_miner.enabled = $enabled' config.json >"$fixture/next.json"
    cp "$fixture/next.json" config.json
    # Capture privately inside the guest; the CLI deliberately prints the password.
    ./pithead apply -y >"$fixture/apply.log" 2>&1
    grep -Fq 'No configuration changes detected' "$fixture/apply.log"
    [ "$(sha256sum .env)" = "$env_before" ]
    [ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot" ]
    if [ "$enabled" = false ]; then
        ! systemctl is-active --quiet xmrig.service || false
        [ "$(systemctl show xmrig.service -p MainPID --value)" = 0 ]
        [ ! -f /data/rigforge/config.json ]
        printf '%s\n' 'local-miner: disable apply stopped xmrig and removed derived config without reboot'
    else
        systemctl is-active --quiet xmrig.service
        pid=$(systemctl show xmrig.service -p MainPID --value)
        [ "$pid" -gt 0 ] && kill -0 "$pid"
        jq -e '.pools[0].url == "127.0.0.1:3333"' /data/rigforge/config.json >/dev/null
        printf '%s\n' 'local-miner: enable apply started xmrig and rendered its pool without reboot'
    fi
done
