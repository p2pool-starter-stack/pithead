# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${SANDBOX:?}"
: "${STACK:?}"

echo "== black-box: an APT-owned install takes no one-click upgrade and no hand-run upgrade (#3459) =="
APTI="$SANDBOX/control-upgrade-apt"
APTREQS="$APTI/data/control/requests"
APTRES="$APTI/data/control/results"
mkdir -p "$APTREQS" "$APTRES" "$APTI/data/control/staged" "$APTI/data/control/audit"
cp "$STACK" "$APTI/pithead"
make_stubs "$APTI/bin"
write_fake_docker "$APTI/bin"
printf '1.3.1' >"$APTI/VERSION"
printf '{}' >"$APTI/config.json"
cat >"$APTI/.env" <<ENV
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$APTI/data/control
NETWORK_PREFIX=10.9.0
ENV
printf '#!/usr/bin/env bash\necho "$*" >>"%s/curl.log"\nexit 22\n' "$APTI" >"$APTI/bin/curl"
chmod +x "$APTI/bin/curl"
APTID="77777777-7777-4777-8777-777777777777"
apti_run() {
    printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$APTID" >"$APTREQS/$APTID.json"
    (cd "$APTI" && PATH="$APTI/bin:$PATH" ./pithead control-run-pending >/dev/null 2>&1)
}

apti_run
assert_eq "control: the install is not APT-owned, so the request reaches the release fetch" \
    "$(jq -r '.error' "$APTRES/$APTID.json" 2>/dev/null | grep -c 'APT package')" "0"
rm -f "$APTRES/$APTID.json" "$APTI/data/control/staged/.upgrade-stamp"
: >"$APTI/curl.log"
: >"$APTI/PITHEAD_PACKAGE"
apti_run
assert_eq "one-click upgrade on an APT install is rejected" "$(jq -r '.status' "$APTRES/$APTID.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the apt command" "$(jq -r '.error' "$APTRES/$APTID.json" 2>/dev/null)" "sudo apt update && sudo apt upgrade"
[ ! -s "$APTI/curl.log" ] && ok "the refusal dials nothing" || bad "the refusal dials nothing" "curl was called"
out="$(cd "$APTI" && PATH="$APTI/bin:$PATH" ./pithead upgrade 2>&1)"
assert_rc "pithead upgrade on an APT install is refused" "$?" "1"
assert_contains "the CLI refusal names the apt command" "$out" "sudo apt update && sudo apt upgrade"
out="$(cd "$APTI" && PATH="$APTI/bin:$PATH" PITHEAD_APT_POSTINST=1 ./pithead upgrade 2>&1)"
assert_not_contains "the package's own stack move is not refused" "$out" "owned by the pithead APT package"
