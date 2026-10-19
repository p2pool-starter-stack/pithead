# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# monerod entrypoint render domain (#2471): the bitmonero.conf that build/monero/entrypoint.sh
# generates, not the template it starts from. Sourced by tests/stack/run.sh.

echo "== unit: monerod entrypoint renders bitmonero.conf (#2471) =="
# Run the real entrypoint end to end with a stub monerod on PATH, so envsubst and the clearnet
# transform both write the file monerod would read. The stub exits at once in place of the daemon.
mon_render() { # <MONERO_CLEARNET_SYNC> -> the db-sync-mode lines of the generated config
    local d
    mk_tmpdir d
    printf '#!/bin/sh\nexit 0\n' >"$d/monerod"
    chmod +x "$d/monerod"
    PATH="$d:$PATH" TEMPLATE_PATH="$ROOT/build/monero/bitmonero.conf.template" \
        CONFIG_PATH="$d/bitmonero.conf" CLEARNET_MARKER="$d/absent" MONERO_CLEARNET_SYNC="$1" \
        bash "$ROOT/build/monero/entrypoint.sh" >/dev/null
    grep -E '^[[:space:]]*db-sync-mode' "$d/bitmonero.conf" || true
    rm -rf "$d"
}
assert_eq "monerod entrypoint: Tor render has exactly db-sync-mode=safe (#2471)" \
    "$(mon_render false)" "db-sync-mode=safe"
assert_eq "monerod entrypoint: clearnet render keeps exactly db-sync-mode=safe (#2471)" \
    "$(mon_render true)" "db-sync-mode=safe"
