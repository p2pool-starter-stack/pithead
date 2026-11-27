# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"

echo "== unit: control commit holds and revalidates the mutation lock =="

CCL="$SANDBOX/control-commit-lock"
CCL_ID="dddddddd-dddd-4ddd-8ddd-dddddddddddd"

control_commit_lock_reset() {
    rm -rf "$CCL"
    mkdir -p "$CCL/control/staged" "$CCL/control/results" "$CCL/control/audit"
    printf '{"label":"A"}\n' >"$CCL/config.json"
    printf '{"label":"B"}\n' >"$CCL/control/staged/$CCL_ID.json"
    sha256sum "$CCL/config.json" | cut -d' ' -f1 >"$CCL/control/staged/.$CCL_ID.base"
    : >"$CCL/actions"
    : >"$CCL/lock"
    : >"$CCL/child"
    : >"$CCL/copy"
    cat >"$CCL/fake-pithead" <<'FAKE'
#!/usr/bin/env bash
if flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null; then
    printf 'free\n' >"$CCL/child"
else
    printf 'held\n' >"$CCL/child"
fi
printf 'child\n' >>"$CCL/actions"
exit "${CHILD_RC:-0}"
FAKE
    chmod +x "$CCL/fake-pithead"
}

control_commit_lock_run() {
    local fake="$CCL/fake-pithead" lock="$CCL/lock"
    STACK="$STACK" CCL="$CCL" CCL_ID="$CCL_ID" PITHEAD_LOCK_FILE="$lock" \
        PITHEAD_LOCK_TIMEOUT="${PITHEAD_LOCK_TIMEOUT:-300}" GATE_DENY="${GATE_DENY:-0}" CHILD_RC="${CHILD_RC:-0}" \
        bash -Eeuo pipefail -c '
        cd "$CCL"
        source "$STACK"
        control_approval_gate() {
            [ "$GATE_DENY" -eq 0 ] || { printf "denied"; return 1; }
            printf "label"
        }
        control_carried_ssh() { return 1; }
        control_reown_operator_files() { :; }
        control_audit() { printf "audit=%s:%s\n" "$4" "$5" >>"$CCL/actions"; }
        control_write_result() { printf "%s\n" "$3" >"$1/$2.json"; }
        cp() {
            if [ "$2" = "$CONFIG_FILE" ]; then
                if flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null; then
                    printf "free\n" >"$CCL/copy"
                else
                    printf "held\n" >"$CCL/copy"
                fi
                printf "copy\n" >>"$CCL/actions"
            fi
            command cp "$@"
        }
        control_commit "$CCL_ID" operator "$CCL/control"
        state=free
        flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null || state=held
        printf "depth=%s state=%s\n" "$_PITHEAD_LOCK_DEPTH" "$state" >"$CCL/balance"
    ' "$fake"
}

control_commit_lock_reset
control_commit_lock_run >/dev/null 2>&1
assert_rc "control commit: a stable preview applies" "$?" 0
assert_eq "control commit: canonical copy runs under the mutation lock" "$(cat "$CCL/copy")" held
assert_eq "control commit: child apply inherits the same held lock" "$(cat "$CCL/child")" held
assert_eq "control commit: staged config becomes canonical" "$(jq -r .label "$CCL/config.json")" B
assert_eq "control commit: result reports the apply" \
    "$(jq -r .status "$CCL/control/results/$CCL_ID.json")" applied
assert_eq "control commit: successful path balances its in-process lock" \
    "$(cat "$CCL/balance")" "depth=0 state=free"
if flock -n "$CCL/lock" true 2>/dev/null; then
    ok "control commit: releases the mutation lock when it finishes"
else
    bad "control commit: releases the mutation lock when it finishes" "the lock remains held"
fi

control_commit_lock_reset
(
    exec 8>"$CCL/lock"
    flock 8
    : >"$CCL/holder-ready"
    holder_polls=0
    while [ ! -f "$CCL/holder-release" ] && [ "$holder_polls" -lt 400 ]; do
        sleep 0.05
        holder_polls=$((holder_polls + 1))
    done
) &
CCL_HOLDER=$!
while [ ! -f "$CCL/holder-ready" ]; do
    kill -0 "$CCL_HOLDER" 2>/dev/null || break
    sleep 0.05
done
control_commit_lock_run >"$CCL/commit.out" 2>&1 &
CCL_COMMIT=$!
CCL_WAITED=0
CCL_POLLS=0
while kill -0 "$CCL_COMMIT" 2>/dev/null && [ "$CCL_POLLS" -lt 200 ]; do
    if grep -q "waiting up to" "$CCL/commit.out" 2>/dev/null; then
        CCL_WAITED=1
        break
    fi
    sleep 0.05
    CCL_POLLS=$((CCL_POLLS + 1))
done
printf '{"label":"C"}\n' >"$CCL/config.json"
: >"$CCL/holder-release"
wait "$CCL_HOLDER"
wait "$CCL_COMMIT"
assert_eq "control commit: waits for an in-flight mutation" "$CCL_WAITED" 1
assert_eq "control commit: revalidates the preview after waiting" \
    "$(jq -r .status "$CCL/control/results/$CCL_ID.json")" rejected
assert_eq "control commit: preserves the newer canonical config" "$(jq -r .label "$CCL/config.json")" C
assert_not_contains "control commit: stale preview is not copied" "$(cat "$CCL/actions")" copy
assert_not_contains "control commit: stale preview does not launch apply" "$(cat "$CCL/actions")" child
assert_eq "control commit: stale rejection balances its in-process lock" \
    "$(cat "$CCL/balance")" "depth=0 state=free"

control_commit_lock_reset
GATE_DENY=1 control_commit_lock_run >/dev/null 2>&1
assert_eq "control commit: denied approval is rejected" \
    "$(jq -r .status "$CCL/control/results/$CCL_ID.json")" rejected
assert_not_contains "control commit: denied approval does not copy config" "$(cat "$CCL/actions")" copy
assert_eq "control commit: approval rejection balances its in-process lock" \
    "$(cat "$CCL/balance")" "depth=0 state=free"

control_commit_lock_reset
CHILD_RC=7 control_commit_lock_run >/dev/null 2>&1
assert_eq "control commit: child apply failure is reported" \
    "$(jq -r .status "$CCL/control/results/$CCL_ID.json")" failed
assert_eq "control commit: child failure balances its in-process lock" \
    "$(cat "$CCL/balance")" "depth=0 state=free"

control_commit_lock_reset
: >"$CCL/control/staged/$CCL_ID.json.confirmed"
exec 8>"$CCL/lock"
flock 8
PITHEAD_LOCK_TIMEOUT=0 control_commit_lock_run >"$CCL/timeout.out" 2>&1
CCL_TIMEOUT_RC=$?
flock -u 8
exec 8>&-
assert_rc "control commit: lock timeout is handled by the commit caller" "$CCL_TIMEOUT_RC" 0
assert_eq "control commit: lock timeout records a terminal rejection" \
    "$(jq -r .status "$CCL/control/results/$CCL_ID.json" 2>/dev/null)" rejected
assert_eq "control commit: lock timeout leaves canonical config unchanged" \
    "$(jq -r .label "$CCL/config.json")" A
assert_not_contains "control commit: lock timeout does not copy config" "$(cat "$CCL/actions")" copy
assert_not_contains "control commit: lock timeout does not launch apply" "$(cat "$CCL/actions")" child
assert_contains "control commit: lock timeout audits the rejection" "$(cat "$CCL/actions")" audit=commit:rejected
assert_eq "control commit: lock timeout removes the staged intent" \
    "$([ -e "$CCL/control/staged/$CCL_ID.json" ] && printf present || printf absent)" absent
assert_eq "control commit: lock timeout removes the preview revision" \
    "$([ -e "$CCL/control/staged/.$CCL_ID.base" ] && printf present || printf absent)" absent
assert_eq "control commit: lock timeout removes the confirmation marker" \
    "$([ -e "$CCL/control/staged/$CCL_ID.json.confirmed" ] && printf present || printf absent)" absent
assert_eq "control commit: lock timeout returns with balanced local state" \
    "$(cat "$CCL/balance" 2>/dev/null)" "depth=0 state=held"

unset -f control_commit_lock_reset control_commit_lock_run
