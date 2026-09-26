#!/usr/bin/env bash
# Failed Docker/SSH observations must not turn into an unrestricted upgrade or a keep verdict.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/chain-keep.sh
source "$HERE/../lib/chain-keep.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
cat >"$WORK/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
if [ "$1" = ps ]; then
    for arg in "$@"; do case "$arg" in label=com.docker.compose.service=*) svc=${arg##*=} ;; esac; done
    [ "${PS_FAIL:-}" != "$svc" ] || exit 1
    [ "${MISSING:-}" != "$svc" ] || exit 0
    echo "$svc"
elif [ "$1" = inspect ]; then
    svc=${*: -1}
    [ "${INSPECT_FAIL:-}" != "$svc" ] || exit 1
    echo "$svc ${svc}id T1 sha256:$svc"
else exit 1; fi
DOCKER
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
CMDS="$WORK/commands"
: >"$CMDS"
on_bench() {
    if [ "$1" = 'bash -s' ]; then bash -s; else
        echo "$1" >>"$CMDS"
        [ "${FAIL_AFTER:-}" != yes ] || export PS_FAIL=tari
    fi
}
warn() { :; }
ok() { :; }
step() { :; }
chain_fingerprint() { echo 'config=c files=f'; }
chain_image_of() { echo "sha256:$2"; }
chain_baseline_current() { echo yes; }
E2E_DIR=/e2e RESTORE_DIR=/baseline
echo "== chain snapshot failures =="
SNAP=$(chain_snapshot)
assert_rc "a readable snapshot succeeds" "$?" 0
assert_eq "the real snapshot script records Tor" "$(chain_snap_get "$SNAP" tor 2)" torid
for fault in PS_FAIL=monerod PS_FAIL=tari INSPECT_FAIL=tor; do
    export "${fault?}"
    chain_snapshot >/dev/null
    assert_rc "$fault propagates instead of returning partial success" "$?" 1
    : >"$CMDS"
    deploy_keeping_chain
    assert_rc "$fault refuses deployment" "$?" 1
    assert_eq "$fault executes no upgrade" "$(cat "$CMDS")" ''
    unset PS_FAIL INSPECT_FAIL
done
FAIL_AFTER=yes deploy_keeping_chain
assert_rc "post-upgrade snapshot failure stops the deploy" "$?" 1
assert_eq "post-upgrade failure never runs a second up" "$(grep -c 'pithead up$' "$CMDS")" 0
unset PS_FAIL
for missing in ' ' 'torid ' ' T1'; do
    assert_eq "incomplete Tor identity is never a match" \
        "$(chain_keep_verdict 'config=c files=f' 'config=c files=f' image image "$missing" "$missing" yes)" 'recreate tor'
done
MISSING=tor deploy_keeping_chain
assert_eq "absent Tor from the real snapshot cannot keep nodes" "$CHAIN_KEPT" ''
CHAIN_BEFORE="$SNAP" CHAIN_MID="$SNAP"
PS_FAIL=tari chain_restore_proof
assert_rc "a failed final snapshot cannot pass restore proof" "$?" 1
PS_FAIL=tari chain_restore_prepare
assert_eq "a failed pre-restore snapshot is recorded" "$CHAIN_MID" unreadable
chain_restore_proof
assert_rc "missing pre-restore evidence cannot pass later" "$?" 1
printf '\nchain snapshot self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
