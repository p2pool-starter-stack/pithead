# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Tari LMDB map headroom and exit status (#2593). The v6 JMT migration drops its legacy tables
# without growing the map first, so the headroom the node keeps before a write is what that drop
# has; at upstream's 64 MB threshold the first attempt failed with MDB_MAP_FULL on mainnet. A
# sibling of test-monero-tari.sh and test-tor-network.sh, both at their budget ceilings.
# Sourced by tests/stack/run.sh.

: "${ROOT:?}" "${SANDBOX:?}"

echo "== tari: LMDB map headroom for the v6 migration, node exit status reaches Docker (#2593) =="
TL_TPL="$ROOT/build/tari/config.toml.template"
# The [base_node.lmdb] table only, so a same-named key elsewhere cannot satisfy it.
tl_lmdb() { awk '/^\[/{s=($0=="[base_node.lmdb]")} s && /^[a-z_]+ *=/' "$TL_TPL"; }
tl_bytes() { tl_lmdb | sed -n "s/^$1 *= *\([0-9_]*\).*/\1/p" | tr -d _; }
# Headroom before a write is min(threshold, grow): below the threshold the map grows by grow only.
TL_GIB=1073741824
assert_eq "tari lmdb: resize threshold keeps at least 1 GiB free before a write (#2593)" \
    "$([ "$(tl_bytes resize_threshold_bytes)" -ge "$TL_GIB" ] 2>/dev/null && echo ok)" "ok"
assert_eq "tari lmdb: each grow adds at least 1 GiB (#2593)" \
    "$([ "$(tl_bytes grow_size_bytes)" -ge "$TL_GIB" ] 2>/dev/null && echo ok)" "ok"
# LMDBConfig is deny_unknown_fields: a misspelt key stops minotari_node from starting at all.
assert_eq "tari lmdb: only keys LMDBConfig accepts (#2593)" \
    "$(tl_lmdb | sed 's/ *=.*//' | grep -cvxE 'init_size_bytes|grow_size_bytes|resize_threshold_bytes|no_read_ahead|compaction_min_free_bytes')" "0"

# A migration failure exits minotari_node with 114 (DatabaseError). The real wrapper runs against a
# stub node that exits 114, so the container's exit code is the node's: nothing in the chain may run
# it as a child and exit 0 afterwards. start_tari_app.sh ships in the upstream image, not here, so
# the stub keeps only its last line as of v6.0.0 (it execs APP_EXEC with the config and base path).
TL_DIR="$SANDBOX/tari-exit"
mkdir -p "$TL_DIR/bin"
printf '#!/usr/bin/env bash\necho "$*" >"%s/node.args"\nexit 114\n' "$TL_DIR" >"$TL_DIR/bin/minotari_node"
# shellcheck disable=SC2016 # the stub expands these when it runs, not here
printf '#!/bin/bash\nexec ${APP_EXEC} --config ${TARI_CONFIG} --base-path ${TARI_BASE} ${@} || exit 1\n' \
    >"$TL_DIR/bin/start_tari_app.sh"
chmod +x "$TL_DIR/bin/minotari_node" "$TL_DIR/bin/start_tari_app.sh"
cp "$TL_TPL" "$TL_DIR/config.toml"
PATH="$TL_DIR/bin:$PATH" APP_EXEC=minotari_node TARI_BASE="$TL_DIR" \
    TARI_CONFIG_SRC="$TL_DIR/config.toml" TARI_CONFIG_RUNTIME="$TL_DIR/rt.toml" \
    CLEARNET_MARKER="$TL_DIR/none" \
    bash "$ROOT/build/tari/entrypoint.sh" --non-interactive >/dev/null 2>&1
assert_rc "tari entrypoint: the node's exit code 114 is the wrapper's (#2593)" "$?" "114"
assert_eq "tari entrypoint: the stub node ran with the runtime config (#2593)" \
    "$(cat "$TL_DIR/node.args" 2>/dev/null)" "--config $TL_DIR/rt.toml --base-path $TL_DIR --non-interactive"
