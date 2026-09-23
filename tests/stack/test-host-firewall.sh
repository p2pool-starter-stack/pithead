# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Host firewall suite: the Tor egress rules' enforcement readback, and the LAN-only source rule on
# the published node ports (#2616). Two fragments, one run.sh entry.
# shellcheck source=tests/stack/test-tor-egress-enforcement.sh
source "$HERE/test-tor-egress-enforcement.sh" || return $?
# shellcheck source=tests/stack/test-lan-guard.sh
source "$HERE/test-lan-guard.sh" || return $?
