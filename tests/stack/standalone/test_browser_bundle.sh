#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPDIR="${TMPDIR:-${RUNNER_TEMP:?set TMPDIR for standalone checks}}"
work=$(mktemp -d "$TMPDIR/pithead-browser-bundle.XXXXXX")
trap 'rm -r -- "$work"' EXIT
mkdir -p "$work/control/results" "$work/control/audit"

# shellcheck source=lib/pithead/07-support-bundle.sh
source "$ROOT/lib/pithead/07-support-bundle.sh"
# shellcheck source=lib/pithead/46a-control-diagnostics.sh
source "$ROOT/lib/pithead/46a-control-diagnostics.sh"
# shellcheck source=lib/pithead/46b-control-browser-bundle.sh
source "$ROOT/lib/pithead/46b-control-browser-bundle.sh"

control_write_result() { printf '%s\n' "$3" >"$1/$2.json"; }
control_audit() { :; }
cat >"$work/doctor" <<'DOCTOR'
#!/usr/bin/env bash
if [ "${BAD_DOCTOR:-0}" = 1 ]; then printf '%s' 'not JSON'; exit 1; fi
printf '{"checks":[{"status":"warn","message":"%s.onion"}],"summary":{"warn":1}}\n' "$(printf 'a%.0s' {1..56})"
exit 1
DOCTOR
chmod 700 "$work/doctor"
PITHEAD_SELF="$work/doctor"
export CALLS="$work/calls"
docker() {
    printf '%s\n' "$*" >>"$CALLS"
    [ "$1 $2 $3 $4 $5" = "compose logs --no-color --tail 200" ]
    case "$6" in wallet-rpc | tari-wallet)
        printf '%s' FORBIDDEN_WALLET_LOG
        return 1
        ;;
    esac
    printf '%s.onion\n' "$(printf 'a%.0s' {1..56})"
}
id="a1111111-1111-4111-8111-111111111111"
jq -n --arg id "$id" '{id:$id,action:"diag-bundle",actor:"operator"}' >"$work/request.json"
control_diag_bundle "$work/request.json" "$id" operator "$work/control"
result="$work/control/results/$id.json"
jq -e '.status == "applied" and .kind == "diag-bundle" and .actor == "operator" and (.bundle.logs | length == 9)' "$result" >/dev/null
jq -e '.bundle.doctor.checks[0].message == "[redacted].onion" and (.bundle.logs | all(.[]; contains("[redacted].onion")))' "$result" >/dev/null
! grep -q 'FORBIDDEN_WALLET_LOG' "$result"
! grep -qE 'wallet-rpc|tari-wallet' "$CALLS"
[ "$(wc -l <"$CALLS" | tr -d ' ')" = 9 ]
[ -z "$(find "$work/control" -maxdepth 1 -name '.diag-bundle.*' -print)" ]

export BAD_DOCTOR=1
control_diag_bundle "$work/request.json" "$id" operator "$work/control"
jq -e '.status == "failed" and (has("bundle") | not)' "$result" >/dev/null
unset BAD_DOCTOR
jq '.container = "wallet-rpc"' "$work/request.json" >"$work/tampered.json"
control_diag_bundle "$work/tampered.json" "$id" operator "$work/control"
jq -e '.status == "rejected"' "$result" >/dev/null
control_diag_bundle "$work/request.json" "$id" '' "$work/control"
jq -e '.status == "rejected"' "$result" >/dev/null
printf '%s\n' 'browser bundle: nine bounded services, redacted doctor, failed collection and tampered requests checked'
