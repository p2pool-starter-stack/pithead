#!/usr/bin/env bash
#
# Self-test for the chain-node keep (#2639): an e2e deploy and its restore leave monerod and tari
# running when the branch leaves their definitions alone, and recreate them when it does not.
#
# The defect it locks down: every deploying e2e run stopped and recreated both chain nodes, because
# the restore ran `pithead down` and because Compose hashes each service's resolved bind-mount
# paths, which differ between the e2e checkout and the baseline. Those nodes also serve other
# benches, so bench-ci had to take its exclusive node guard for every such run.
#
# What is proven here, against the SHIPPED lib/chain-keep.sh:
#   1. chain_fingerprint, the real remote script run locally over a stub `docker` and two fixture
#      checkouts: the checkout path is normalized away, a changed environment, network, mounted
#      file or in-checkout data path is not, the image tag is not compared, and no value leaves.
#   2. chain_keep_verdict and grade_chain_restore, the two pure decisions.
#   3. deploy_keeping_chain and chain_restore_prepare, driven against stubs.
# Then a mutation battery puts each defect back in a COPY of the module and requires a RED.
#
# Standalone; run directly or via `make test-integration-selftest`. No bench, no rig, no docker.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
KEEP_SRC="$HERE/../lib/chain-keep.sh"
E2E_SRC="$HERE/../e2e.sh"
# shellcheck source=tests/integration/lib/chain-keep.sh
source "$KEEP_SRC"
assert_eq "chain-keep.sh defines deploy_keeping_chain" "$(type -t deploy_keeping_chain)" "function"

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
STUB="$WORK/bin"
mkdir -p "$STUB"
# The stub answers from the checkout it runs in, as Compose does: compose.json is that checkout's
# rendered `docker compose config --format json`.
cat >"$STUB/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"compose config")
    if [ "${3:-}" = --services ]; then
        [ -n "${STUB_SERVICES:-}" ] || exit 1
        printf '%s\n' $STUB_SERVICES
        exit 0
    fi
    [ -f compose.json ] && cat compose.json ;;
"image inspect")
    case "${*: -1}" in reg/pithead-monero:dev) echo sha256:monero-dev ;; *) exit 1 ;; esac ;;
"ps -a") printf '%s\n' "${STUB_PS:-}" | sed '/^$/d' ;;
"rm -f") echo "$3" >>"$STUB_RM_LOG" ;;
*) exit 1 ;;
esac
EOF
chmod +x "$STUB/docker"
export PATH="$STUB:$PATH" STUB_RM_LOG="$WORK/rm.log"
on_bench() { bash -c "$1"; }
ok() { :; }
step() { :; }
warn() { :; }

compose_json() { # <checkout> -> the rendered config Compose would print for it
    jq -n --arg d "$1" '{name: "pithead", services: {
      monerod: {image: "reg/pithead-monero:dev", build: {context: ($d + "/build/monero")},
        environment: {MONERO_PRUNE: "true", MONERO_NODE_PASSWORD: "fixture-secret-7731"},
        networks: {mining_net: {ipv4_address: "172.28.0.26"}},
        volumes: [{type: "bind", source: "/chains/monero", target: "/home/ubuntu/.bitmonero"},
          {type: "bind", source: ($d + "/build/monero/bitmonero.conf.template"), target: "/home/ubuntu/bitmonero.conf.template", read_only: true},
          {type: "bind", source: ($d + "/data/clearnet-state"), target: "/clearnet-state", read_only: true}]},
      tari: {image: "reg/minotari:v6@sha256:abc", environment: {TARI_CLEARNET_SYNC: "false"},
        networks: {mining_net: {ipv4_address: "172.28.0.27"}},
        volumes: [{type: "bind", source: "/chains/tari", target: "/var/tari/node"},
          {type: "bind", source: ($d + "/build/tari"), target: "/var/tari/config"},
          {type: "bind", source: ($d + "/data/clearnet-state"), target: "/clearnet-state", read_only: true}]}},
      networks: {mining_net: {ipam: {config: [{subnet: "172.28.0.0/24"}]}}, proxy_net: {ipam: {}}}}'
}
checkout() { # <dir>: a checkout with the mounted files and its own rendered config
    rm -rf "$1"
    mkdir -p "$1/build/tari" "$1/build/monero" "$1/data/clearnet-state"
    printf 'entry\n' >"$1/build/tari/entrypoint.sh"
    printf 'config\n' >"$1/build/tari/config.toml"
    printf 'template\n' >"$1/build/monero/bitmonero.conf.template"
    printf 'done\n' >"$1/data/clearnet-state/monero"
    compose_json "$1" >"$1/compose.json"
}
edit_json() { jq "$2" "$1/compose.json" >"$1/compose.tmp" && mv "$1/compose.tmp" "$1/compose.json"; }
A="$WORK/baseline" B="$WORK/pithead-e2e"
fp() { chain_fingerprint "$1" "$2"; }
cfg_of() { fp "$1" "$2" | sed -n 's/^config=\([^ ]*\) .*/\1/p'; }
files_of() { fp "$1" "$2" | sed -n 's/.* files=//p'; }

run_fingerprint_assertions() {
    echo "== chain_fingerprint: the real remote script over a stub docker =="
    checkout "$A" && checkout "$B"
    assert_contains "a fingerprint names both halves" "$(fp "$A" tari)" "files="
    assert_eq "the same node in two checkouts fingerprints the same (tari)" "$(fp "$A" tari)" "$(fp "$B" tari)"
    assert_eq "the same node in two checkouts fingerprints the same (monerod)" "$(fp "$A" monerod)" "$(fp "$B" monerod)"
    assert_eq "no value from the config leaves the box" \
        "$(fp "$A" monerod | grep -c 'fixture-secret-7731')" "0"
    assert_eq "an unknown service yields no fingerprint" "$(fp "$A" nosuch)" ""

    edit_json "$B" '.services.tari.image = "reg/minotari:v7"'
    assert_eq "the image tag is not part of the definition (IDs are compared separately)" "$(fp "$A" tari)" "$(fp "$B" tari)"
    checkout "$B" && edit_json "$B" '.services.tari.environment.TARI_CLEARNET_SYNC = "true"'
    assert_ne "a changed environment changes the definition" "$(cfg_of "$A" tari)" "$(cfg_of "$B" tari)"
    checkout "$B" && edit_json "$B" '.networks.mining_net.ipam.config[0].subnet = "10.84.0.0/24"'
    assert_ne "a changed attached network changes the definition" "$(cfg_of "$A" tari)" "$(cfg_of "$B" tari)"
    checkout "$B" && edit_json "$B" '.networks.proxy_net.ipam = {config: [{subnet: "10.9.0.0/24"}]}'
    assert_eq "a network the node is not on does not" "$(fp "$A" tari)" "$(fp "$B" tari)"

    checkout "$B" && printf 'entry v2\n' >"$B/build/tari/entrypoint.sh"
    assert_eq "an edited entrypoint leaves the rendered config alone" "$(cfg_of "$A" tari)" "$(cfg_of "$B" tari)"
    assert_ne "an edited entrypoint changes the mounted files" "$(files_of "$A" tari)" "$(files_of "$B" tari)"
    checkout "$B" && printf 'template v2\n' >"$B/build/monero/bitmonero.conf.template"
    assert_ne "an edited monero template changes the mounted files" "$(files_of "$A" monerod)" "$(files_of "$B" monerod)"
    checkout "$B" && rm "$B/data/clearnet-state/monero"
    assert_ne "a read-only mount inside the checkout is hashed too" "$(files_of "$A" tari)" "$(files_of "$B" tari)"
    checkout "$B" && rm -r "$B/build/tari"
    assert_ne "a missing mount source never matches a present one" "$(files_of "$A" tari)" "$(files_of "$B" tari)"

    # A writable mount inside the checkout is that checkout's own state (a chain dir left at its
    # default under ./data): the path stays literal, so two checkouts never read as one node.
    checkout "$A" && checkout "$B"
    edit_json "$A" ".services.monerod.volumes[0].source = \"$A/data/monero\""
    edit_json "$B" ".services.monerod.volumes[0].source = \"$B/data/monero\""
    assert_ne "a writable mount inside the checkout is compared by its real path" "$(cfg_of "$A" monerod)" "$(cfg_of "$B" monerod)"

    # Compose may print the physical path while the shell sits in a symlink to the checkout.
    checkout "$A" && checkout "$B" && ln -sfn "$B" "$WORK/current"
    assert_eq "a checkout reached through a symlink normalizes the same" "$(fp "$A" tari)" "$(fp "$WORK/current" tari)"

    checkout "$B" && chmod 000 "$B/build/tari/config.toml"
    if [ -r "$B/build/tari/config.toml" ]; then
        it_pass "unreadable mount: not checkable as this user (root reads mode 000), skipped"
    else
        assert_eq "an unreadable mounted file is reported, never hashed as empty" "$(files_of "$B" tari)" "unreadable"
    fi
    chmod 644 "$B/build/tari/config.toml"
}

run_decision_assertions() {
    echo "== chain_keep_verdict =="
    local fp1="config=c1 files=f1" t="tid 2026-09-24T00:00:00Z"
    assert_eq "all three match: keep" "$(chain_keep_verdict tari "$fp1" "$fp1" sha256:i sha256:i "" "")" "keep"
    assert_eq "a different definition recreates" \
        "$(chain_keep_verdict tari "$fp1" "config=c2 files=f1" sha256:i sha256:i "" "")" "recreate definition"
    assert_eq "different mounted files recreate" \
        "$(chain_keep_verdict tari "$fp1" "config=c1 files=f2" sha256:i sha256:i "" "")" "recreate definition"
    assert_eq "a different image ID recreates, whatever the tags say" \
        "$(chain_keep_verdict monerod "$fp1" "$fp1" sha256:vX sha256:dev "$t" "$t")" "recreate image"
    assert_eq "an image the branch never produced recreates" \
        "$(chain_keep_verdict tari "$fp1" "$fp1" sha256:i "" "" "")" "recreate image"
    assert_eq "a fingerprint that could not be read never reads as a match" \
        "$(chain_keep_verdict tari "" "" sha256:i sha256:i "" "")" "recreate definition"
    assert_eq "unreadable mounted files never read as a match" \
        "$(chain_keep_verdict tari "config=c1 files=unreadable" "config=c1 files=unreadable" sha256:i sha256:i "" "")" "recreate definition"
    assert_eq "monerod is recreated when the deploy moved tor (#972)" \
        "$(chain_keep_verdict monerod "$fp1" "$fp1" sha256:i sha256:i "$t" "tid2 2026-09-24T00:01:00Z")" "recreate tor"
    assert_eq "monerod is kept when tor kept its container" \
        "$(chain_keep_verdict monerod "$fp1" "$fp1" sha256:i sha256:i "$t" "$t")" "keep"
    assert_eq "tari does not depend on tor's container" \
        "$(chain_keep_verdict tari "$fp1" "$fp1" sha256:i sha256:i "$t" "tid2 x")" "keep"

    echo "== grade_chain_restore =="
    local before="monerod m1 T1 sha256:m
tari t1 T1 sha256:t
tor o1 T1 sha256:o"
    assert_eq "the same containers, never restarted, are untouched" \
        "$(grade_chain_restore "monerod tari" "$before" "$before" "$before" | tr '\n' ' ')" "untouched monerod untouched tari "
    assert_eq "--lifecycle's stop and start reads as restarted, not recreated" \
        "$(grade_chain_restore "monerod tari" "$before" "$before" "monerod m1 T2 sha256:m" | head -n1)" "restarted monerod"
    assert_eq "a kept node the restore recreated is broken" \
        "$(grade_chain_restore "monerod tari" "$before" "$before" "tari t9 T3 sha256:t" | sed -n 2p)" "broken tari"
    assert_eq "a kept node the harness recreated (fault injection) is recreated, not broken" \
        "$(grade_chain_restore "monerod tari" "$before" "monerod m5 T2 sha256:m" "monerod m9 T3 sha256:m" | head -n1)" "recreated monerod"
    assert_eq "a node the deploy recreated is recreated, not broken" \
        "$(grade_chain_restore "tari" "$before" "$before" "monerod m9 T3 sha256:m" | head -n1)" "recreated monerod"
    assert_eq "a node not running after the restore is gone" \
        "$(grade_chain_restore "monerod tari" "$before" "$before" "tari t1 T1 sha256:t" | head -n1)" "gone monerod"
    assert_eq "a node that was not running before the deploy is not graded" \
        "$(grade_chain_restore "" "tari t1 T1 sha256:t" "" "tari t1 T1 sha256:t" | tr '\n' ' ')" "untouched tari "
    assert_eq "chain_snap_get matches the whole service name" "$(chain_snap_get "$before" tor 2)" "o1"
    CHAIN_KEPT="tari" CHAIN_BEFORE="$before" CHAIN_MID="$before"
    chain_snapshot() { printf 'monerod m1 T1 sha256:m\ntor o1 T1 sha256:o\ntari t9 T3 sha256:t\n'; }
    chain_restore_proof
    assert_rc "the restore proof fails on a broken node" "$?" "1"
    chain_snapshot() { printf '%s\n' "$before"; }
    chain_restore_proof
    assert_rc "the restore proof passes when the nodes are untouched" "$?" "0"
    CHAIN_BEFORE=""
    chain_restore_proof
    assert_rc "no deploy snapshot (a --mode check run): nothing to grade" "$?" "0"
}

# deploy_keeping_chain against stubs: the commands it gives the box, and what it decides.
drive_deploy() { # <before> <after> <tari-branch-fp> -> commands, then "KEPT=<list>"
    (
        E2E_DIR=/e2e RESTORE_DIR=/base CMDS="$WORK/cmds" SNAPS="$WORK/snaps"
        : >"$CMDS" && echo 0 >"$SNAPS"
        BEFORE="$1" AFTER="$2" TARI_FP="$3"
        on_bench() { echo "$1" >>"$CMDS"; }
        chain_snapshot() {
            local n
            n=$(($(cat "$SNAPS") + 1)) && echo "$n" >"$SNAPS"
            if [ "$n" -eq 1 ]; then printf '%s\n' "$BEFORE"; else printf '%s\n' "$AFTER"; fi
        }
        chain_fingerprint() { if [ "$1:$2" = /e2e:tari ]; then echo "$TARI_FP"; else echo "config=c files=f"; fi; }
        chain_image_of() { case "$2" in monerod) echo sha256:m ;; tari) echo sha256:t ;; esac }
        deploy_keeping_chain
        echo "rc=$?"
        cat "$CMDS"
        echo "KEPT=$CHAIN_KEPT"
    )
}

run_deploy_assertions() {
    echo "== deploy_keeping_chain =="
    local snap="monerod m1 T1 sha256:m
tari t1 T1 sha256:t
tor o1 T1 sha256:o" out
    out="$(drive_deploy "$snap" "$snap" "config=c files=f")"
    assert_contains "the upgrade holds both running nodes out" "$out" "cd '/e2e' && PITHEAD_KEEP_RUNNING='monerod tari' ./pithead upgrade"
    assert_contains "the branch's monerod is built so its image ID can be compared" "$out" "compose build monerod"
    assert_eq "both unchanged: no second up" "$(printf '%s\n' "$out" | grep -c 'pithead up$')" "0"
    assert_eq "both unchanged: both kept" "$(printf '%s\n' "$out" | tail -n1)" "KEPT=monerod tari"
    out="$(drive_deploy "$snap" "$snap" "config=c files=f2")"
    assert_contains "a changed tari is recreated with monerod still held" "$out" "cd '/e2e' && PITHEAD_KEEP_RUNNING='monerod' ./pithead up"
    assert_eq "a changed tari is not kept" "$(printf '%s\n' "$out" | tail -n1)" "KEPT=monerod"
    out="$(drive_deploy "$snap" "monerod m1 T1 sha256:m
tari t1 T1 sha256:t
tor o2 T2 sha256:o2" "config=c files=f2")"
    assert_contains "both recreated: the second up holds nothing" "$out" "cd '/e2e' && ./pithead up"
    assert_eq "both recreated: none kept" "$(printf '%s\n' "$out" | tail -n1)" "KEPT="
    out="$(drive_deploy "" "" "config=c files=f")"
    assert_contains "no node running: a plain upgrade" "$out" "cd '/e2e' && ./pithead upgrade"
    assert_eq "no node running: no knob" "$(printf '%s\n' "$out" | grep -c PITHEAD_KEEP_RUNNING)" "0"
    out="$(drive_deploy "tari t1 T1 sha256:t" "tari t1 T1 sha256:t" "config=c files=f")"
    assert_contains "only the running node is held" "$out" "PITHEAD_KEEP_RUNNING='tari' ./pithead upgrade"
    assert_eq "no monerod held: nothing built for it" "$(printf '%s\n' "$out" | grep -c 'compose build')" "0"

    echo "== chain_restore_prepare =="
    checkout "$A"
    RESTORE_DIR="$A" STUB_SERVICES="tor monerod tari" STUB_PS="c1 tor
c2 monerod
c3 newsvc"
    export STUB_SERVICES STUB_PS
    : >"$STUB_RM_LOG"
    chain_snapshot() { :; }
    chain_restore_prepare
    assert_eq "only a service the baseline does not define is removed" "$(cat "$STUB_RM_LOG")" "c3"
    : >"$STUB_RM_LOG"
    STUB_SERVICES="" chain_restore_prepare
    assert_eq "an unreadable baseline service list removes nothing" "$(cat "$STUB_RM_LOG")" ""
    unset STUB_SERVICES STUB_PS
}

run_all() {
    run_fingerprint_assertions
    run_decision_assertions
    run_deploy_assertions
}
run_all

echo "== e2e.sh wiring =="
DEPLOY_SRC="$(sed -n '/^deploy_branch() {$/,/^}$/p' "$E2E_SRC")"
assert_contains "deploy_branch deploys through deploy_keeping_chain" "$DEPLOY_SRC" "deploy_keeping_chain || die"
assert_eq "deploy_branch no longer runs a bare upgrade itself" "$(printf '%s\n' "$DEPLOY_SRC" | grep -c "./pithead upgrade\"")" "0"
assert_eq "e2e.sh sources chain-keep.sh" "$(grep -c 'source "$HERE/lib/chain-keep.sh"' "$E2E_SRC")" "1"

# --- Mutation battery -------------------------------------------------------------------------
echo "== mutation battery: every mutant must kill at least one assertion =="
mutate_and_count_fails() { # <sed-expr> -> failed assertions under the mutant
    local mutant
    if sed "$1" "$KEEP_SRC" | diff -q - "$KEEP_SRC" >/dev/null 2>&1; then
        echo "MUTANT DID NOT APPLY"
        return 0
    fi
    mutant="$(mktemp)"
    sed "$1" "$KEEP_SRC" >"$mutant"
    (
        IT_PASS=0 IT_FAIL=0
        # shellcheck disable=SC1090
        source "$mutant"
        run_all >/dev/null 2>&1
        printf '%s' "$IT_FAIL"
    )
    rm -f "$mutant"
}
assert_num_ge "M1 (tor ignored for monerod) is killed" "$(mutate_and_count_fails 's/\[ "\$1" != monerod \] ||/true ||/')" 1
assert_num_ge "M2 (image ID not compared) is killed" "$(mutate_and_count_fails 's/{ \[ -n "\$4" \] && \[ "\$4" = "\$5" \]; }/true/')" 1
assert_num_ge "M3 (read-only in-checkout mounts not hashed) is killed" "$(mutate_and_count_fails 's/\.read_only == true or //')" 1
assert_num_ge "M4 (a broken node graded recreated) is killed" "$(mutate_and_count_fails 's/echo "broken \$svc"/echo "recreated $svc"/')" 1
assert_num_ge "M5 (the checkout path not normalized) is killed" "$(mutate_and_count_fails 's/if hashed then .source = rel(.source) else . end/./')" 1
assert_num_ge "M6 (the deploy holds nothing out) is killed" "$(mutate_and_count_fails "s/PITHEAD_KEEP_RUNNING='\$held' //")" 1

printf '\nchain-keep self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
