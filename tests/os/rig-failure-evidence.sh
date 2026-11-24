#!/usr/bin/env bash
# shellcheck source=tests/os/lib/redact-addr.sh
source "${BASH_SOURCE[0]%/*}/lib/redact-addr.sh"

rig_failure_evidence_script() {
    cat <<'GUEST'
since=$(cat /run/pithead-t3375/backup-start-at 2>/dev/null || true)
echo '-- coordinator journal from the backup apply --'
if [ -n "$since" ]; then
    journalctl --no-pager --since "@$since" 2>&1 | tail -n 400
else
    journalctl --no-pager -n 200 2>&1
fi
for c in xmrig-proxy p2pool; do
    echo "-- $c container log --"
    podman logs --tail 150 "$c" 2>&1
done
echo '-- proxy summary --'
timeout 15 podman exec dashboard python -c "
import json, os
from mining_dashboard.helper.http import bounded_get
r = bounded_get('http://{}:{}/1/summary'.format(os.environ['PROXY_HOST'], os.environ['PROXY_API_PORT']), headers={'Authorization': 'Bearer ' + os.environ['PROXY_AUTH_TOKEN']}, timeout=5)
r.raise_for_status()
print(json.dumps(r.json(), sort_keys=True)[:4000])
" 2>&1
echo '-- containers --'
podman ps -a --format '{{.Names}} {{.Status}}' 2>&1
GUEST
}

rig_failure_evidence() {
    printf '     --- rig failure diagnostics ---\n'
    _ssh "$(rig_failure_evidence_script)" 2>&1 | tr -d '\r' | os_redact_addr | sed 's/^/     · /' || true
}
