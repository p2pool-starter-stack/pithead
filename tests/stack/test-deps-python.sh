# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Python is required for safe host-owned clearnet marker attestation.
echo "== unit: host marker attestation needs python3 (#2678) =="
DEPS_PY="$SANDBOX/deps-python"
make_stubs "$DEPS_PY/bin"
# shellcheck disable=SC1090
(
    cd "$SANDBOX" && PATH="$DEPS_PY/bin:$PATH" && source "$STACK" 2>/dev/null
    set +e
    command() { [ "$1 $2" != '-v python3' ] && builtin command "$@"; }
    deps_satisfied
)
assert_rc "deps_satisfied false without python3" "$?" "1"
