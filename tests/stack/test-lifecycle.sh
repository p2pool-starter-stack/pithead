# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Lifecycle suite split at its existing recovery, lock primitive, verb wiring, and appliance seams.
# shellcheck source=tests/stack/lifecycle/recovery.sh
source "$HERE/lifecycle/recovery.sh" || return $?
# shellcheck source=tests/stack/lifecycle/lock-core.sh
source "$HERE/lifecycle/lock-core.sh" || return $?
# shellcheck source=tests/stack/lifecycle/lock-wiring.sh
source "$HERE/lifecycle/lock-wiring.sh" || return $?
# shellcheck source=tests/stack/lifecycle/appliance-lock.sh
source "$HERE/lifecycle/appliance-lock.sh" || return $?
