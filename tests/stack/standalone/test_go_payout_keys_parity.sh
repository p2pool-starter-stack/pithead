#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STACK="$ROOT/pithead"
BINARY="$ROOT/go/bin/pithead"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pithead-go-payout-keys-parity.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
CHECKS=0

echo "== unit: payout-keys Go helpers answer byte-identically to the Bash reference (#4220) =="

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    [ -z "${2:-}" ] || printf '  %s\n' "$2" >&2
    exit 1
}

bump() {
    CHECKS=$((CHECKS + 1))
    printf '.'
}

[ -f "$STACK" ] || fail "the generated CLI is missing" "run: make pithead"
[ -x "$BINARY" ] || fail "the Go helper binary is missing" "run: make go-build"

xmr=48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD
xmr_sub=888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H
tari_dual=126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ
tari_single=1224yPceFvbksLKQ8JE6APDzVY2D6P3SpXwB5LLC3BH4F7oF
tari_emoji='🐢📟🍼🌈🍓🚓➕🎸🍆🍷🎣🍗📿😂🥊⏰🍯👾🤔👒🍾👀🍼🌊🎷📟😈🚨👙🍈🌈🛵🤢🍔🔋👙🚽🤑🎽🎓🎓🐀🐜🐴🥄🚿📷💰👶👍🎉🍄🎢🔌🐋🚰🚑💅👢🦂🐬🐋🍗🍸🎹🏀🍄'
scalar="01$(printf '00%.0s' $(seq 31))"

run_case() {
    local rc=0
    if [ "$2" = "-" ]; then
        env "PITHEAD_IMPL=$1" bash -c 'source "$1" >/dev/null 2>&1 || exit 9
            shift; "$@"' _ "$STACK" "$3" "$4" >"$WORK/out.$5" 2>"$WORK/err.$5" || rc=$?
    else
        env "PITHEAD_IMPL=$1" "$2" bash -c 'source "$1" >/dev/null 2>&1 || exit 9
            shift; "$@"' _ "$STACK" "$3" "$4" >"$WORK/out.$5" 2>"$WORK/err.$5" || rc=$?
    fi
    printf '%s' "$rc" >"$WORK/rc.$5"
}

compare_sides() {
    CHECKS=$((CHECKS + 1))
    cmp -s "$WORK/out.b" "$WORK/out.g" ||
        fail "$1: stdout differs between the Bash reference and the Go path" \
            "bash: [$(cat "$WORK/out.b")] go: [$(cat "$WORK/out.g")]"
    CHECKS=$((CHECKS + 1))
    cmp -s "$WORK/err.b" "$WORK/err.g" ||
        fail "$1: stderr differs between the Bash reference and the Go path" \
            "bash: [$(cat "$WORK/err.b")] go: [$(cat "$WORK/err.g")]"
    CHECKS=$((CHECKS + 1))
    [ "$(cat "$WORK/rc.b")" = "$(cat "$WORK/rc.g")" ] ||
        fail "$1: exit status differs" \
            "bash: $(cat "$WORK/rc.b") go: $(cat "$WORK/rc.g")"
    printf '.'
}

parity() {
    if [ -n "${5:-}" ]; then
        export PITHEAD_GO_BINARY="$5"
        run_case bash "$3" "$2" "$4" b
        run_case payout-keys "$3" "$2" "$4" g
        unset PITHEAD_GO_BINARY
    else
        run_case bash "$3" "$2" "$4" b
        run_case payout-keys "$3" "$2" "$4" g
    fi
    compare_sides "$1"
}

run_pyshim() {
    local mode tag rc
    for mode in bash payout-keys; do
        case "$mode" in
        bash) tag=b ;;
        *) tag=g ;;
        esac
        rc=0
        env "PITHEAD_IMPL=$mode" bash -c 'source "$1" >/dev/null 2>&1 || exit 9
            python3() { return 127; }
            shift; "$@"' _ "$STACK" "$2" "$3" >"$WORK/out.$tag" 2>"$WORK/err.$tag" || rc=$?
        printf '%s' "$rc" >"$WORK/rc.$tag"
    done
    compare_sides "$1"
}

while IFS=$'\t' read -r name fn assign arg; do
    [ -n "$name" ] || continue
    case "$arg" in
    @xmr) arg="$xmr" ;;
    @xmr_sub) arg="$xmr_sub" ;;
    @tari) arg="$tari_dual" ;;
    @tari_single) arg="$tari_single" ;;
    @tari_emoji) arg="$tari_emoji" ;;
    esac
    parity "$name" "$fn" "$assign" "$arg"
done <<'TABLE'
monero primary	monero_address_type	-	@xmr
monero subaddress	monero_address_type	-	@xmr_sub
monero integrated	monero_address_type	-	4JMJg6ic6R584YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijGDpDGTWtLM516v46mB
monero bad checksum	monero_address_type	-	4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
monero bad subaddress checksum	monero_address_type	-	8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
monero non-base58	monero_address_type	-	40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
monero one char too many	monero_address_type	-	48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoDx
monero not an address	monero_address_type	-	not-an-address
monero empty	monero_address_type	-
monero non-ascii	monero_address_type	-	4🐢AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
monero key-only	monero_address_type	MONERO_ADDRESS_KEY_ONLY=1	@xmr
monero key-only bad	monero_address_type	MONERO_ADDRESS_KEY_ONLY=1	not-an-address
monero key-only off	monero_address_type	MONERO_ADDRESS_KEY_ONLY=0	@xmr
monero seen by the tari gate	monero_address_type	-	@tari
tari dual	tari_address_type	-	@tari
tari single	tari_address_type	-	@tari_single
tari emoji	tari_address_type	-	@tari_emoji
tari wrong network	tari_address_type	-	f26J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Cb
tari unknown feature	tari_address_type	-	1A6J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Dr
tari flipped character	tari_address_type	-	126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5B0
tari below minimum length	tari_address_type	-	1224yPceFvbksLKQ8JE6APDzVY2D6P3SpXwB5LLC3BH4F7o
tari monero address	tari_address_type	-	@xmr
tari empty	tari_address_type	-
tari key-only dual	tari_address_type	TARI_ADDRESS_KEY_ONLY=1	@tari
tari key-only single	tari_address_type	TARI_ADDRESS_KEY_ONLY=1	@tari_single
tari key-only bad	tari_address_type	TARI_ADDRESS_KEY_ONLY=1	not-an-address
TABLE

run_derive() {
    local mode rc bin="${4:-}" shim="${5:-}"
    for mode in bash payout-keys; do
        rc=0
        if [ -n "$bin" ]; then
            PITHEAD_GO_BINARY="$bin" env "PITHEAD_IMPL=$mode" bash -c 'source "$1" >/dev/null 2>&1 || exit 9
                [ -n "${4:-}" ] && python3() { return 127; }
                payout_public_view_key "$2" "$3"' \
                _ "$STACK" "$2" "$3" "$shim" >"$WORK/out.$mode" 2>"$WORK/err.$mode" || rc=$?
        else
            env "PITHEAD_IMPL=$mode" bash -c 'source "$1" >/dev/null 2>&1 || exit 9
                [ -n "${4:-}" ] && python3() { return 127; }
                payout_public_view_key "$2" "$3"' \
                _ "$STACK" "$2" "$3" "$shim" >"$WORK/out.$mode" 2>"$WORK/err.$mode" || rc=$?
        fi
        printf '%s' "$rc" >"$WORK/rc.$mode"
    done
    CHECKS=$((CHECKS + 1))
    cmp -s "$WORK/out.bash" "$WORK/out.payout-keys" &&
        cmp -s "$WORK/err.bash" "$WORK/err.payout-keys" ||
        fail "$1: output differs between the Bash reference and the Go path" \
            "bash: [$(cat "$WORK/out.bash")] go: [$(cat "$WORK/out.payout-keys")]"
    CHECKS=$((CHECKS + 1))
    [ "$(cat "$WORK/rc.bash")" = "$(cat "$WORK/rc.payout-keys")" ] ||
        fail "$1: exit status differs"
    printf '.'
}

run_derive 'derive monero scalar' monero "$scalar"
run_derive 'derive tari scalar' tari "02$(printf '00%.0s' $(seq 31))"
run_derive 'derive uppercase hex' monero "0A$(printf '00%.0s' $(seq 31))"
run_derive 'derive zero scalar' monero "$(printf '00%.0s' $(seq 32))"
run_derive 'derive above group order' monero "$(printf '00%.0s' $(seq 30))FF0F"
run_derive 'derive odd length' monero 010
run_derive 'derive bad hex' monero "$(printf 'zz%.0s' 1)$(printf '00%.0s' $(seq 31))"
run_derive 'derive empty scalar' monero ""
run_derive 'derive empty chain' "" "$scalar"
run_derive 'derive unknown chain' ripple "$scalar"
run_derive 'derive without a live python3' monero "$scalar" "" pyshim

echo

run_pyshim 'monero shape-only without a live python3' monero_address_type "$xmr"
run_pyshim 'tari unchecked without a live python3' tari_address_type "$tari_dual"

echo
echo "== unit: the NUL-framed helper protocol and the Bash fallbacks =="

address_request() { printf 'monero\x000\x00%s\x00' "$1"; }
printf 'primary\0' >"$WORK/direct.want"
address_request "$xmr" | "$BINARY" >"$WORK/direct.out" 2>/dev/null || true
! cmp -s "$WORK/direct.out" "$WORK/direct.want" ||
    fail "the binary must answer the helper protocol only when selected" "unselected run answered it"
bump
address_request "$xmr" | PITHEAD_GO_HELPER=payout-keys-address "$BINARY" >"$WORK/direct.out"
cmp -s "$WORK/direct.out" "$WORK/direct.want" ||
    fail "the address helper must answer the NUL-framed protocol" \
        "got [$(cat "$WORK/direct.out")]"
bump
printf 'tari\x000\x00%s\x00' "$tari_dual" | PITHEAD_GO_HELPER=payout-keys-address "$BINARY" >"$WORK/direct.out"
printf 'ok\0' >"$WORK/direct.want"
cmp -s "$WORK/direct.out" "$WORK/direct.want" ||
    fail "the address helper must answer the NUL-framed protocol for tari" \
        "got [$(cat "$WORK/direct.out")]"
bump
printf 'tari\x001\x00%s\x00' "$tari_single" | PITHEAD_GO_HELPER=payout-keys-address "$BINARY" >"$WORK/direct.out"
if ! {
    IFS= read -r -d '' tari_keys <"$WORK/direct.out" && [ "${#tari_keys}" -eq 66 ] &&
        [ -z "${tari_keys//[0-9a-f]/}" ]
}; then
    fail "the tari key-only helper must answer with 66 hex digits terminated by a NUL" \
        "got [$(cat "$WORK/direct.out")]"
fi
bump
printf 'monero\x00%s\x00' "$scalar" | PITHEAD_GO_HELPER=payout-keys-derive "$BINARY" >"$WORK/direct.out"
printf '5866666666666666666666666666666666666666666666666666666666666666\0' >"$WORK/direct.want"
cmp -s "$WORK/direct.out" "$WORK/direct.want" ||
    fail "the derive helper must answer the NUL-framed protocol" \
        "got [$(cat "$WORK/direct.out")]"
bump
{
    printf 'monero\x000\x00'
    printf abc
} | PITHEAD_GO_HELPER=payout-keys-address "$BINARY" >"$WORK/direct.out" 2>/dev/null && direct_rc=0 || direct_rc=$?
[ "$direct_rc" != 0 ] && [ ! -s "$WORK/direct.out" ] ||
    fail "an unterminated helper request must fail without output" "rc=$direct_rc"
bump

stub() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" >"$WORK/$1.sh"
    chmod +x "$WORK/$1.sh"
    printf '%s\n' "$WORK/$1.sh"
}

fail3=$(stub fail3 'printf "ok\0"; exit 3')
halluc=$(stub halluc 'cat >/dev/null; printf "HALLUCINATED\0"')
noterm=$(stub noterm 'cat >/dev/null; printf ok')
extraf=$(stub extraf 'cat >/dev/null; printf "ok\0tail\0"')
missing=$(stub missing 'exit 127')
answer=$(stub answer 'cat >/dev/null; printf "subaddress\0"')

parity 'a helper failure falls back to Bash' monero_address_type - "$xmr" "$fail3"
parity 'a verdict off the whitelist falls back' monero_address_type - "$xmr" "$halluc"
parity 'an unterminated verdict falls back' monero_address_type - "$xmr" "$noterm"
parity 'extra fields fall back' monero_address_type - "$xmr" "$extraf"
parity 'a missing binary falls back' monero_address_type - "$xmr" "$missing"
parity 'a helper failure falls back to Bash (tari)' tari_address_type - "$tari_dual" "$fail3"
parity 'a verdict off the whitelist falls back (tari)' tari_address_type - "$tari_dual" "$halluc"
parity 'an unterminated verdict falls back (tari)' tari_address_type - "$tari_dual" "$noterm"
parity 'extra fields fall back (tari)' tari_address_type - "$tari_dual" "$extraf"
parity 'a missing binary falls back (tari)' tari_address_type - "$tari_dual" "$missing"
run_derive 'a derive helper failure falls back' monero "$scalar" "$fail3"
run_derive 'a derive key off the shape gate falls back' monero "$scalar" "$halluc"
run_derive 'a missing derive binary falls back' monero "$scalar" "$WORK/no-such-binary"

out=$(PITHEAD_IMPL=payout-keys PITHEAD_GO_BINARY="$answer" bash -c \
    'source "$1" >/dev/null 2>&1 || exit 9; monero_address_type "$2"' _ "$STACK" "$xmr")
[ "$out" = subaddress ] || fail "the selected piece must echo the Go helper's own verdict" "got [$out]"
bump

answer_tari=$(stub answer_tari 'cat >/dev/null; printf "network\0"')
out=$(PITHEAD_IMPL=payout-keys PITHEAD_GO_BINARY="$answer_tari" bash -c \
    'source "$1" >/dev/null 2>&1 || exit 9; tari_address_type "$2"' _ "$STACK" "$tari_dual")
[ "$out" = network ] ||
    fail "the selected piece must echo the Go helper's own tari verdict" "got [$out]"
bump

answer_tari_keys=$(stub answer_tari_keys 'cat >/dev/null; printf "00%.0s" $(seq 33); printf "\0"')
out=$(PITHEAD_IMPL=payout-keys PITHEAD_GO_BINARY="$answer_tari_keys" TARI_ADDRESS_KEY_ONLY=1 bash -c \
    'source "$1" >/dev/null 2>&1 || exit 9; tari_address_type "$2"' _ "$STACK" "$tari_dual")
[ "$out" = "$(printf '00%.0s' $(seq 33))" ] ||
    fail "the selected piece must echo the tari key-only helper's own keys" "got [$out]"
bump

derive_answer=$(stub derive_answer 'cat >/dev/null; printf "5a%.0s" $(seq 32); printf "\0"')
out=$(PITHEAD_IMPL=payout-keys PITHEAD_GO_BINARY="$derive_answer" bash -c \
    'source "$1" >/dev/null 2>&1 || exit 9; payout_public_view_key monero "$2"' _ "$STACK" "$scalar")
[ "$out" = "$(printf '5a%.0s' $(seq 32))" ] ||
    fail "the selected piece must echo the derive helper's own key" "got [$out]"
bump

argv_probe=$(stub argv_probe '{
    printf "argv:%s\n" "$*"
    env | sed -n "s/^PITHEAD_VIEW_SCALAR=.*/env-leak:PITHEAD_VIEW_SCALAR/p"
    printf "stdin:"
    cat | tr -d "\000"
} >"$PITHEAD_PARITY_PROBE"
printf "5b%.0s" $(seq 32); printf "\0"')
secret="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
out=$(PITHEAD_IMPL=payout-keys PITHEAD_GO_BINARY="$argv_probe" PITHEAD_PARITY_PROBE="$WORK/probe.txt" bash -c \
    'source "$1" >/dev/null 2>&1 || exit 9; payout_public_view_key monero "$2"' _ "$STACK" "$secret")
[ "$out" = "$(printf '5b%.0s' $(seq 32))" ] || fail "the argv probe helper should have answered" "got [$out]"
probe_text=$(cat "$WORK/probe.txt")
case "$probe_text" in
"argv:$secret"* | *env-leak:* | *"argv:$scalar"*)
    fail "the private view key must reach the helper over stdin only" "probe: [$probe_text]"
    ;;
*"stdin:monero$secret"*) ;;
*) fail "the derive helper must receive chain and secret on stdin" "probe: [$probe_text]" ;;
esac
bump

mkdir -p "$WORK/fakeroot/go/bin"
ln -s "$STACK" "$WORK/fakeroot/pithead"
cp "$answer" "$WORK/fakeroot/go/bin/pithead"
out=$(PITHEAD_IMPL=payout-keys bash -c 'source "$1" >/dev/null 2>&1 || exit 9; monero_address_type "$2"' \
    _ "$WORK/fakeroot/pithead" "$xmr")
[ "$out" = subaddress ] ||
    fail "the helper must be discovered beside the CLI when nothing points at it" "got [$out]"
bump

echo
echo "== unit: the Go binary hands argv and streams back to the Bash reference (selection.md) =="

bash_out=$(PITHEAD_IMPL=bash "$STACK" version 2>&1) && bash_rc=0 || bash_rc=$?
go_out=$(PITHEAD_GO_REFERENCE="$STACK" "$BINARY" version 2>&1) && go_rc=0 || go_rc=$?
[ "$go_out" = "$bash_out" ] && [ "$go_rc" = "$bash_rc" ] ||
    fail "the handoff must reproduce the Bash reference for version" \
        "bash rc=$bash_rc [$bash_out] go rc=$go_rc [$go_out]"
bump

go_out=$(PITHEAD_IMPL=status PITHEAD_GO_REFERENCE="$STACK" "$BINARY" version 2>&1) && go_rc=0 || go_rc=$?
[ "$go_out" = "$bash_out" ] && [ "$go_rc" = "$bash_rc" ] ||
    fail "the handoff must force PITHEAD_IMPL=bash for argv it does not own" \
        "got rc=$go_rc [$go_out]"
bump

bad_out=$(PITHEAD_IMPL=bash "$STACK" definitely-not-a-verb 2>&1) && bad_rc=0 || bad_rc=$?
go_out=$(PITHEAD_GO_REFERENCE="$STACK" "$BINARY" definitely-not-a-verb 2>&1) && go_rc=0 || go_rc=$?
[ "$go_out" = "$bad_out" ] && [ "$go_rc" = "$bad_rc" ] ||
    fail "the handoff must forward argv and the exit status unchanged" \
        "bash rc=$bad_rc [$bad_out] go rc=$go_rc [$go_out]"
bump

printf '\nPASS: payout-keys Go/Bash byte parity (%s checks)\n' "$CHECKS"
