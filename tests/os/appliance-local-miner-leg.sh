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
        ! systemctl is-active --quiet xmrig.service
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
