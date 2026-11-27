#!/usr/bin/env bash
# Check the guest probe's failure verdict and restoration without a VM or a host service.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
echo "== local-miner guest probe convergence and restoration =="
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/stack" "$fixture/rigforge" "$fixture/bin"
printf '{"local_miner":{"enabled":true},"unrelated":"preserved"}\n' >"$fixture/original.json"
printf 'unchanged-env\n' >"$fixture/stack/.env"
sed -e "s|/data/pithead|$fixture/stack|g" -e "s|/data/rigforge|$fixture/rigforge|g" \
    "$ROOT/tests/os/appliance-local-miner-leg.sh" >"$fixture/probe.sh"
cat >"$fixture/stack/pithead" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "${OMIT_CONVERGENCE:-0}" != 1 ]; then
    if [ "$(jq -r '.local_miner.enabled' config.json)" = true ]; then
        echo active >"$FIXTURE_ROOT/active"
        printf '{"pools":[{"url":"127.0.0.1:3333"}]}\n' >"$FIXTURE_ROOT/rigforge/config.json"
    else
        rm -f "$FIXTURE_ROOT/active" "$FIXTURE_ROOT/rigforge/config.json"
    fi
fi
echo 'No configuration changes detected'
FAKE
cat >"$fixture/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = is-active ]; then [ -f "$FIXTURE_ROOT/active" ];
elif [ -f "$FIXTURE_ROOT/active" ]; then echo "$FIXTURE_PARENT_PID";
else echo 0; fi
FAKE
chmod +x "$fixture/stack/pithead" "$fixture/bin/systemctl"
export FIXTURE_ROOT="$fixture" FIXTURE_PARENT_PID=$$ PATH="$fixture/bin:$PATH"
# The guest sets TMPDIR explicitly; a GitHub unit runner need not have it exported.
export TMPDIR="$fixture"
cp "$fixture/original.json" "$fixture/stack/config.json"
echo active >"$fixture/active"
bash "$fixture/probe.sh" >"$fixture/output" 2>&1
grep -Fq 'local-miner: enable apply started xmrig and rendered its pool without reboot' "$fixture/output"
grep -Fq 'local-miner: original configuration restored' "$fixture/output"
cmp "$fixture/original.json" "$fixture/stack/config.json"
echo 'PASS: both guest toggle assertions complete and original config is restored'
if OMIT_CONVERGENCE=1 bash "$fixture/probe.sh" >"$fixture/output" 2>&1; then
    echo 'FAIL: absent miner convergence was accepted' >&2
    exit 1
fi
cmp "$fixture/original.json" "$fixture/stack/config.json"
echo 'PASS: absent convergence fails and original config is restored'
