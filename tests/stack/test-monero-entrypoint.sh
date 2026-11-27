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

echo "== unit: monerod entrypoint writes bitmonero.conf owner-only =="
mk_tmpdir MON_MODE
mon_start() {
    mkdir -p "$MON_MODE/$1/bin" "$MON_MODE/$1/data"
    printf '#!/bin/sh\numask >"%s"\n' "$MON_MODE/$1/umask" >"$MON_MODE/$1/bin/monerod"
    chmod +x "$MON_MODE/$1/bin/monerod"
    (
        umask 022
        PATH="$MON_MODE/$1/bin:$PATH" TEMPLATE_PATH="$ROOT/build/monero/bitmonero.conf.template" \
            CONFIG_PATH="$MON_MODE/$1/data/bitmonero.conf" CLEARNET_MARKER="$MON_MODE/absent" \
            MONERO_CLEARNET_SYNC="$2" MONERO_NODE_USERNAME=u1 MONERO_NODE_PASSWORD=p1 bash "$ROOT/build/monero/entrypoint.sh" >/dev/null 2>&1
    )
}
mkdir -p "$MON_MODE/over/data" "$MON_MODE/fail/bin" "$MON_MODE/fail/data"
printf 'old\n' >"$MON_MODE/over/data/bitmonero.conf"
printf 'old\n' >"$MON_MODE/fail/data/bitmonero.conf"
chmod 644 "$MON_MODE/over/data/bitmonero.conf" "$MON_MODE/fail/data/bitmonero.conf"
printf '#!/bin/sh\nprintf partial\nexit 1\n' >"$MON_MODE/fail/bin/envsubst"
chmod +x "$MON_MODE/fail/bin/envsubst"
mon_start fresh false
mon_start over false
mon_start clearnet true
mon_start fail false
assert_eq "monerod entrypoint: a new bitmonero.conf is mode 600" "$(file_mode "$MON_MODE/fresh/data/bitmonero.conf")" "600"
assert_eq "monerod entrypoint: a new bitmonero.conf carries the node login and no placeholder" \
    "$(grep -c '^rpc-login=u1:p1$' "$MON_MODE/fresh/data/bitmonero.conf") $(grep -c '\${' "$MON_MODE/fresh/data/bitmonero.conf")" "1 0"
assert_eq "monerod entrypoint: a bitmonero.conf left at 644 ends mode 600" "$(file_mode "$MON_MODE/over/data/bitmonero.conf")" "600"
assert_eq "monerod entrypoint: the replaced bitmonero.conf matches a new render byte for byte" \
    "$(cmp "$MON_MODE/over/data/bitmonero.conf" "$MON_MODE/fresh/data/bitmonero.conf" && echo same)" "same"
assert_eq "monerod entrypoint: a clearnet bitmonero.conf is mode 600" "$(file_mode "$MON_MODE/clearnet/data/bitmonero.conf")" "600"
assert_eq "monerod entrypoint: monerod starts with the umask the entrypoint was given" "$(cat "$MON_MODE/fresh/umask")" "0022"
assert_eq "monerod entrypoint: a failed render keeps the previous bitmonero.conf" "$(cat "$MON_MODE/fail/data/bitmonero.conf")" "old"
assert_eq "monerod entrypoint: a failed render leaves no other file and starts nothing" \
    "$(ls -A "$MON_MODE/fail/data" && [ ! -e "$MON_MODE/fail/umask" ] || echo started)" "bitmonero.conf"
rm -rf "$MON_MODE"
