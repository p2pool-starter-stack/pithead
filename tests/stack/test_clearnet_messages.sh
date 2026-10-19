#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== clearnet transition operator messages =="
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"
build_val_sandbox
seed_env
printf 'MONERO_CLEARNET_SYNC=true\nTARI_CLEARNET_SYNC=false\n' >>"$V/.env"
printf '#!/usr/bin/env bash\nexit 1\n' >"$V/bin/curl"
chmod +x "$V/bin/curl"
probe() {
    (cd "$V" && PATH="$V/bin:$PATH" ./pithead "$@" 2>&1) || true
}
for state in pending marker verified stale; do
    mkdir -p "$V/data/clearnet-state" "$V/data/control/results"
    if [ "$state" != pending ]; then
        printf '00000000-0000-4000-8000-000000000001\n' >"$V/data/clearnet-state/monero.synced"
        chmod 644 "$V/data/clearnet-state/monero.synced"
    fi
    if [ "$state" = verified ]; then
        python3 - "$V" <<'PYFIXTURE'
import json, os, sys
from pathlib import Path
root = Path(sys.argv[1])
marker = root / "data/clearnet-state/monero.synced"
st = marker.stat()
(root / "data/control/results/clearnet-monero-tor.json").write_text(json.dumps({
    "status": "verified", "marker": marker.read_text().strip(),
    "inode": st.st_ino, "ctime_ns": st.st_ctime_ns,
}))
PYFIXTURE
        mkdir -p "$V/python-fixture"
        cat >"$V/python-fixture/sitecustomize.py" <<'PYOWNER'
import os
from types import SimpleNamespace

original = os.fstat

def host_owner(fd):
    st = original(fd)
    values = {key: getattr(st, key) for key in dir(st) if key.startswith("st_")}
    values["st_uid"] = 0
    return SimpleNamespace(**values)

os.fstat = host_owner
PYOWNER
        export PYTHONPATH="$V/python-fixture"
    elif [ "$state" = stale ]; then
        printf '00000000-0000-4000-8000-000000000002\n' >"$V/data/clearnet-state/monero.synced"
    fi
    status="$(probe status)"
    doctor="$(probe doctor --json)"
    if [ "$state" = verified ]; then
        assert_not_contains "verified status clears banner" "$status" "CLEARNET INITIAL SYNC OR TOR TRANSITION PENDING"
        assert_contains "verified doctor gives all-clear" "$doctor" "all node P2P is Tor-only."
        assert_not_contains "verified doctor clears warning" "$doctor" "CLEARNET initial sync or Tor transition is pending"
    else
        assert_contains "$state status keeps banner" "$status" "CLEARNET INITIAL SYNC OR TOR TRANSITION PENDING"
        assert_contains "$state status names Monero" "$status" "Monero P2P may expose this host's IP"
        assert_contains "$state doctor warns" "$doctor" "CLEARNET initial sync or Tor transition is pending for Monero"
        assert_not_contains "$state doctor cannot give all-clear" "$doctor" "all node P2P is Tor-only."
        assert_contains "$state doctor records WARN" "$doctor" '"warn"'
    fi
done
unset PYTHONPATH
printf 'clearnet messages: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
