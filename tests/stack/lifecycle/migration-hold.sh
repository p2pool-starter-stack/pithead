# shellcheck shell=bash
: "${STACK_SUITE:?source via the stack suite}"
echo "== black-box: 'pithead up' under the migration hold starts everything but the chain (#851) =="
# PITHEAD_HOLD_CHAIN=1 is set by the appliance boot path on the first boot of a data_migration
# bundle: the chain services (the lmdb holders) must not start before the A/B slot commits. The
# compose service list comes from a dedicated stub because the shared one answers nothing for
# `compose config --services`, and stack_status's tests rely on exactly that.
HCB="$SANDBOX/hold-chain-bin"
mkdir -p "$HCB"
cat >"$HCB/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
"compose up "*)
    if [ -n "${HOLD_RESET_PATH:-}" ]; then
        [ -f "$HOLD_RESET_PATH" ] && [ ! -s "$HOLD_RESET_PATH" ] || exit 1
    fi
    ;;
"compose config --services") printf 'tor\nmonerod\ntari\nwallet-rpc\ntari-wallet\np2pool\nxmrig-proxy\ncaddy\ndashboard\n' ;;
esac
exit 0
EOF
chmod +x "$HCB/docker"
HOLD_LOG=$(mktemp)
printf '{}\n' >"$V/config.json"
seed_env
hold_dashboard="$V/data/dashboard"
printf 'DASHBOARD_DATA_DIR=%s\n' "$hold_dashboard" >>"$V/.env"
mkdir -p "$hold_dashboard"
printf 'tari-only\n' >"$hold_dashboard/sync-gate-reset"
out="$(cd "$V" && HOLD_RESET_PATH="$hold_dashboard/sync-gate-reset" DOCKER_LOG="$HOLD_LOG" PATH="$HCB:$V/bin:$PATH" PITHEAD_HOLD_CHAIN=1 ./pithead up 2>&1)"
assert_rc "up succeeds under the hold" "$?" "0"
assert_eq "migration replaces a Tari-only reset with a full mining reset" "$(wc -c <"$hold_dashboard/sync-gate-reset" | tr -d ' ')" "0"
assert_contains "the hold is announced for the journal" "$out" "holding chain services"
up_line=$(grep "compose up" "$HOLD_LOG" | tail -1)
assert_contains "tor still starts under the hold" "$up_line" "tor"
assert_contains "p2pool still starts under the hold" "$up_line" "p2pool"
assert_contains "the dashboard still starts under the hold" "$up_line" "dashboard"
assert_not_contains "monerod is withheld" "$up_line" "monerod"
assert_not_contains "tari and tari-wallet are withheld" "$up_line" "tari"
assert_not_contains "wallet-rpc is withheld" "$up_line" "wallet-rpc"
# A failed marker publication must abort before any compose startup.
rm -f "$hold_dashboard/sync-gate-reset"
mkdir "$hold_dashboard/sync-gate-reset"
: >"$HOLD_LOG"
(cd "$V" && DOCKER_LOG="$HOLD_LOG" PATH="$HCB:$V/bin:$PATH" PITHEAD_HOLD_CHAIN=1 ./pithead up >/dev/null 2>&1)
assert_rc "a failed migration reset refuses startup" "$?" 1
assert_not_contains "a failed reset starts no container" "$(cat "$HOLD_LOG")" "compose up"
rmdir "$hold_dashboard/sync-gate-reset"
# Without the env the same sandbox starts the whole stack — the hold is opt-in per boot.
HOLD_LOG2=$(mktemp)
rm -f "$hold_dashboard/sync-gate-reset"
(cd "$V" && DOCKER_LOG="$HOLD_LOG2" PATH="$HCB:$V/bin:$PATH" ./pithead up >/dev/null 2>&1)
up_line2=$(grep "compose up" "$HOLD_LOG2" | tail -1)
assert_eq "normal up preserves the earned latch without a reset" "$([ -e "$hold_dashboard/sync-gate-reset" ] && echo present || echo absent)" absent
assert_not_contains "a plain up names no service subset" "$up_line2" "p2pool"
rm -f "$HOLD_LOG" "$HOLD_LOG2"
