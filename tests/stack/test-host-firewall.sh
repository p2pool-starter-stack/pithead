# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Host firewall suite: the Tor egress rules' enforcement readback, and the LAN-only source rule on
# the published node ports (#2616) and its teardown (#2749). Three fragments, one run.sh entry.
# shellcheck source=tests/stack/firewall/tor-egress-enforcement.sh
source "$HERE/firewall/tor-egress-enforcement.sh" || return $?
# shellcheck source=tests/stack/firewall/lan-guard.sh
source "$HERE/firewall/lan-guard.sh" || return $?
# shellcheck source=tests/stack/firewall/lan-guard-entrypoints.sh
source "$HERE/firewall/lan-guard-entrypoints.sh" || return $?
# shellcheck source=tests/stack/firewall/lan-guard-first-network.sh
source "$HERE/firewall/lan-guard-first-network.sh" || return $?
# shellcheck source=tests/stack/firewall/lan-guard-teardown.sh
source "$HERE/firewall/lan-guard-teardown.sh" || return $?
