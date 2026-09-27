# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Python is required for safe host-owned clearnet marker attestation.
# shellcheck disable=SC1090
(
    cd "$SANDBOX" && PATH="$DEPS/bin:$PATH" && source "$STACK" 2>/dev/null
    set +e
    command() { [ "$1 $2" != '-v python3' ] && builtin command "$@"; }
    deps_satisfied
)
assert_rc "deps_satisfied false without python3" "$?" "1"
