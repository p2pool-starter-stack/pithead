#!/usr/bin/env bash
# Fixed read-only remote collector, streamed by soak-probe.sh in its one SSH session.
set -u
printf 'btime=%s\n' "$(awk '/^btime/{print $2}' /proc/stat)"
printf 'jdirs=%s\n' "$(ls /var/log/journal 2>/dev/null | wc -l)"
printf 'uptime_s=%s\n' "$(awk '{print int($1)}' /proc/uptime)"
printf 'load=%s\n' "$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')"
printf 'data_free_mb=%s\n' "$(df -Pk /data 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
printf 'rauc=%s\n' "$(rauc status --output-format=shell 2>/dev/null | awk -F= '/^RAUC_SYSTEM_BOOTED_BOOTNAME=/{b=$2} /^RAUC_BOOT_PRIMARY=/{p=$2} END{gsub(/\x27/,"",b); gsub(/\x27/,"",p); printf "%s/%s", b, p}')"
for c in $(podman ps -aq 2>/dev/null); do
    podman inspect -f 'container={{.Name}}|{{.State.Status}}|{{.RestartCount}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.StartedAt}}' "$c" 2>/dev/null
done
if [ -n "${SOAK_CURSOR:-}" ]; then
    printf 'ssh_window=cursor\n'
    printf 'ssh_accepted=%s\n' "$(journalctl -m -u ssh --after-cursor="$SOAK_CURSOR" --no-pager -q 2>/dev/null | grep -c 'Accepted ')"
else
    printf 'ssh_window=25h\n'
    printf 'ssh_accepted=%s\n' "$(journalctl -m -u ssh --since '-25h' --no-pager -q 2>/dev/null | grep -c 'Accepted ')"
fi
printf 'ssh_cursor=%s\n' "$(journalctl -m -u ssh -n1 --no-pager -q -o cat --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')"
printf 'last_sessions=%s\n' "$(last -F 2>/dev/null | grep -v -c -E '^(reboot|wtmp|$)')"
env_get() { sed -n "s/^$1=//p" /data/pithead/.env 2>/dev/null | head -1 | tr -d '"'; }
mu=$(env_get MONERO_NODE_USERNAME); mp=$(env_get MONERO_NODE_PASSWORD); murl=$(env_get MONERO_RPC_URL); [ -n "$murl" ] || murl=http://127.0.0.1:18081
if [ -n "$mu" ]; then body=$(curl -fsS --max-time 8 --digest -u "$mu:$mp" "$murl/get_info" 2>/dev/null); else body=$(curl -fsS --max-time 8 "$murl/get_info" 2>/dev/null); fi
printf 'monero=%s\n' "$(printf '%s' "${body:-null}" | jq -r '"h:\(.height // "?") sync:\(.synchronized // "?") peers:\(if .restricted == true then "restricted" else "\(.incoming_connections_count // "?")/\(.outgoing_connections_count // "?")" end)"' 2>/dev/null || echo 'h:? sync:? peers:?/?')"
