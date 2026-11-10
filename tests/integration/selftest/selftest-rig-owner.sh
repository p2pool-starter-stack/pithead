#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/rig-owner.sh
source "$HERE/../lib/rig-owner.sh"

echo "== the harness owner marker names a live pid while held and is gone after release (#3985) =="
d="$(mktemp -d)"
trap 'rig_owner_release; rm -rf "$d"' EXIT
mkdir "$d/bin"
cat >"$d/bin/ssh" <<'SH'
#!/usr/bin/env bash
eval "last=\${$#}"
exec bash -c "$last"
SH
cat >"$d/bin/sudo" <<'SH'
#!/usr/bin/env bash
[ "$1" = -n ] && shift
exec "$@"
SH
chmod +x "$d/bin/ssh" "$d/bin/sudo"
PATH="$d/bin:$PATH"
export RIGFORGE_RIG_OWNER_MARKER="$d/owner"
SSH_OPTS=(-o BatchMode=yes)
MINER_HOST=rig.invalid
warn() { :; }

rig_owner_hold
assert_rc "hold succeeds against a reachable rig" "$?" 0
pid="$(tr -d '[:space:]' <"$d/owner" 2>/dev/null)"
assert_eq "the marker holds a numeric pid" "$([[ "$pid" =~ ^[0-9]+$ ]] && echo yes)" "yes"
kill -0 "$pid" 2>/dev/null
assert_rc "the pid in the marker is alive while the run holds it" "$?" 0
rig_owner_release
assert_eq "release removes the marker" "$(test -e "$d/owner" && echo present || echo gone)" "gone"
kill -0 "$pid" 2>/dev/null
assert_rc "the marker's pid is gone after release" "$?" 1

cat >"$d/bin/sudo" <<'SH'
#!/usr/bin/env bash
exit 1
SH
rig_owner_hold
assert_rc "hold reports failure when the marker cannot be written" "$?" 1
assert_eq "a failed hold leaves no marker" "$(test -e "$d/owner" && echo present || echo gone)" "gone"

echo "selftest-rig-owner: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
