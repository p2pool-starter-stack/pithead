# shellcheck shell=bash
set -uo pipefail
saved_impl="${PITHEAD_IMPL-}"
saved_binary="${PITHEAD_GO_BINARY-}"
saved_document_binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY-}"
saved_untrusted="${PITHEAD_UNTRUSTED_MACOS_RUN-}"
saved_only_keep="${PITHEAD_SCOPE_ONLY_KEEP-0}"
saved_call_log="${PITHEAD_SCOPE_CALL_LOG-}"
saved_fragment_log="${PITHEAD_SCOPE_FRAGMENT_LOG-}"
ROOT="${PITHEAD_SCOPE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$ROOT/tests/stack/lib.sh"
PITHEAD_IMPL="$saved_impl"
PITHEAD_GO_BINARY="$saved_binary"
PITHEAD_GO_CONFIG_DOCUMENT_BINARY="$saved_document_binary"
PITHEAD_UNTRUSTED_MACOS_RUN="$saved_untrusted"
PITHEAD_SCOPE_ONLY_KEEP="$saved_only_keep"
PITHEAD_SCOPE_CALL_LOG="$saved_call_log"
PITHEAD_SCOPE_FRAGMENT_LOG="$saved_fragment_log"
export PITHEAD_IMPL PITHEAD_GO_BINARY PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_UNTRUSTED_MACOS_RUN
HERE="$ROOT/tests/stack"
build_val_sandbox
scope_before() {
    SCOPE_BEFORE=0
    if [ -n "${PITHEAD_SCOPE_CALL_LOG:-}" ] && [ -f "$PITHEAD_SCOPE_CALL_LOG" ]; then SCOPE_BEFORE="$(wc -l <"$PITHEAD_SCOPE_CALL_LOG")"; fi
}
scope_after() {
    local name="$1" rc="$2" after=0
    if [ -n "${PITHEAD_SCOPE_CALL_LOG:-}" ] && [ -f "$PITHEAD_SCOPE_CALL_LOG" ]; then after="$(wc -l <"$PITHEAD_SCOPE_CALL_LOG")"; fi
    if [ -n "${PITHEAD_SCOPE_FRAGMENT_LOG:-}" ]; then printf '%s %d %d\n' "$name" "$((after - SCOPE_BEFORE))" "$rc" >>"$PITHEAD_SCOPE_FRAGMENT_LOG"; fi
}
if [ "${PITHEAD_SCOPE_ONLY_KEEP:-0}" != 1 ]; then
    _d0=$((PASS + FAIL))
    scope_before
    source "$ROOT/tests/stack/lifecycle/lock-core.sh"
    _scope_rc=$?
    scope_after lock-core "$_scope_rc"
    domain_ran lock-core.sh "$_d0" "$_scope_rc"
    _d0=$((PASS + FAIL))
    scope_before
    source "$ROOT/tests/stack/lifecycle/lock-wiring.sh"
    _scope_rc=$?
    scope_after lock-wiring "$_scope_rc"
    domain_ran lock-wiring.sh "$_d0" "$_scope_rc"
fi
_d0=$((PASS + FAIL))
scope_before
source "$ROOT/tests/stack/lifecycle/keep-running.sh"
_scope_rc=$?
scope_after keep-running "$_scope_rc"
domain_ran keep-running.sh "$_d0" "$_scope_rc"
if [ "${PITHEAD_SCOPE_ONLY_KEEP:-0}" != 1 ]; then
    _d0=$((PASS + FAIL))
    scope_before
    source "$ROOT/tests/stack/firewall/lan-guard.sh"
    _scope_rc=$?
    scope_after lan-guard "$_scope_rc"
    domain_ran lan-guard.sh "$_d0" "$_scope_rc"
    _d0=$((PASS + FAIL))
    scope_before
    source "$ROOT/tests/stack/firewall/lan-guard-first-network.sh"
    _scope_rc=$?
    scope_after first-network "$_scope_rc"
    domain_ran lan-guard-first-network.sh "$_d0" "$_scope_rc"
fi
[ "$FAIL" -eq 0 ]
