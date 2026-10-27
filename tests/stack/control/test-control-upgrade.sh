# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
build_control_sandbox
# shellcheck disable=SC2034
WALLET="$VALID_PRIMARY"
seed_control_env
control_config main
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
REQS="$C/data/control/requests"
RESULTS="$C/data/control/results"

echo "== black-box: a failed upgrade never repoints the control-runner units (#1070) =="
upg_step_order() {
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        require_env() { :; }
        ensure_onion_password() { :; }
        parse_and_validate_config() { :; }
        load_preserved_state() { :; }
        ensure_directories() { :; }
        resolve_dashboard_host() { :; }
        render_env() { [ -n "${1:-}" ] && : >"$1"; }
        provision_node_onions() { :; }
        inject_service_configs() { :; }
        generate_caddyfile() { :; }
        migrate_compose_project() { :; }
        apply_tor_egress_firewall() { :; }
        provision_egress_check_units() { :; }
        provision_lan_guard_check_units() { :; }
        migrate_dashboard_data() { :; }
        is_source_checkout() { return 1; }
        log() { :; }
        eval "verify_release_images() { $1 }"
        compose_up_checked() { echo compose; }
        update_current_symlink() { echo symlink; }
        provision_control_runner() { echo provision; }
        stack_upgrade
    ) | grep -xE 'verify|compose|symlink|provision' | tr '\n' ','
}
assert_eq "successful upgrade provisions the units only after 'current ->' moves (#1070)" \
    "$(upg_step_order 'echo verify;')" "verify,compose,symlink,provision,"
assert_eq "an upgrade that aborts at the gate repoints no units and moves no symlink (#1070)" \
    "$(upg_step_order 'echo verify; error "gate refused";')" "verify,"

echo "== unit: a spent GitHub rate limit is not a dead Tor circuit (#1081) =="
GHR="$SANDBOX/gh-release"
mkdir -p "$GHR/bin"
cat >"$GHR/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Answers with $GH_STUB_CODE and $GH_STUB_BODY, in the shape `-w '\n%{http_code}'` produces.
[ "${GH_STUB_TRANSPORT_FAIL:-0}" = "1" ] && exit 7
[ "${GH_STUB_NOCODE:-0}" = "1" ] && { printf '%s' "${GH_STUB_BODY:-}"; exit 0; }
printf '%s\n%s' "${GH_STUB_BODY:-}" "${GH_STUB_CODE:-200}"
EOF
chmod +x "$GHR/bin/curl"
gh_fetch() {
    (
        cd "$GHR" || exit 1
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        export PATH="$GHR/bin:$PATH" GH_STUB_CODE="$1" GH_STUB_BODY="$2" GH_STUB_TRANSPORT_FAIL="${3:-0}"
        gh_release_fetch p2pool-starter-stack/pithead
        printf '%s|%s|%s' "$?" "$GH_RELEASE_JSON" "$GH_RELEASE_HINT"
    )
}
gh_ok=$(gh_fetch 200 '{"tag_name":"v1.2.3"}')
assert_eq "a 200 returns the release JSON" "${gh_ok%%|*}" "0"
assert_contains "and the JSON is what the caller gets" "$gh_ok" '"tag_name":"v1.2.3"'

gh_rl=$(gh_fetch 403 '{"message":"API rate limit exceeded for 203.0.113.9."}')
assert_eq "a spent rate limit is a failure" "${gh_rl%%|*}" "1"
assert_contains "and names the remedy that actually works" "$gh_rl" "restart tor"
case "$gh_rl" in
*"could not reach the GitHub release API"*) bad "a spent rate limit is not reported as unreachable" "the hint still blames the dial: $gh_rl" ;;
*) ok "a spent rate limit is not reported as unreachable" ;;
esac

gh_tf=$(gh_fetch 000 '' 1)
assert_eq "a transport failure is still a failure, now distinctly rc 2 (#1050)" "${gh_tf%%|*}" "2"
assert_contains "and still reads as a dial that did not land" "$gh_tf" "could not reach the GitHub release API"
case "$gh_tf" in
*"restart tor"*) bad "a dial failure is not blamed on the rate limit" "the hint sends them to restart tor: $gh_tf" ;;
*) ok "a dial failure is not blamed on the rate limit" ;;
esac

gh_nocode=$(
    cd "$GHR" || exit 1
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    set +e
    export PATH="$GHR/bin:$PATH" GH_STUB_BODY='{"message":"Not Found"}' GH_STUB_NOCODE=1
    gh_release_fetch p2pool-starter-stack/pithead
    printf '%s|%s' "$?" "$GH_RELEASE_HINT"
)
assert_eq "a response with no status line is a failure" "${gh_nocode%%|*}" "1"
case "$gh_nocode" in
*'{"message"'* | *'Not Found'*) bad "the body never reaches the operator" "the hint quotes the response body: $gh_nocode" ;;
*) ok "the body never reaches the operator" ;;
esac

gh_500=$(gh_fetch 500 'upstream is unwell')
assert_eq "a server error is a failure" "${gh_500%%|*}" "1"
assert_contains "and says which status came back" "$gh_500" "HTTP 500"

assert_eq "every release lookup uses the shared fetch" \
    "$(grep -c 'gh_release_fetch p2pool-starter-stack/' "$STACK")" "3"
assert_eq "no release lookup dials the API directly any more" \
    "$(grep -c 'api.github.com/repos/.*/releases/latest' "$STACK")" "1"
assert_eq "neither caller swallows the hint in a subshell" \
    "$(grep -cF '=$(gh_release_fetch' "$STACK")" "0"
assert_eq "the appliance os-check does not swallow the hint either" \
    "$(grep -cF '=$(os_release_fetch' "$STACK")" "0"
assert_eq "every dial on the upgrade path uses the address the lookup derived" \
    "$(grep -cF -- '--socks5-hostname "$GH_SOCKS"' "$STACK")" "3"
undeclared_socks="$(awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { fn = $1; declared = 0 }
    fn && /^ *local .*socks/ { declared = 1 }
    /--socks5-hostname "\$socks"/ && !declared { print FNR " in " fn }
' "$STACK")"
assert_eq "no dial refers to a socks variable its own function never declares" "$undeclared_socks" ""

echo "== unit: appliance-lane release-fetch hints name no shell the box does not have (#1139) =="
gh_tf_appliance=$(PITHEAD_APPLIANCE=1 gh_fetch 000 '' 1)
assert_eq "appliance transport failure is still a failure, now distinctly rc 2 (#1050)" "${gh_tf_appliance%%|*}" "2"
assert_contains "and still reads as a dial that did not land" "$gh_tf_appliance" "could not reach the GitHub release API"
assert_contains "and points at the dashboard instead of a shell" "$gh_tf_appliance" "Retry from the dashboard"
case "$gh_tf_appliance" in
*"./pithead"*) bad "appliance transport-failure hint names no CLI verb" "still says: $gh_tf_appliance" ;;
*) ok "appliance transport-failure hint names no CLI verb" ;;
esac

gh_nocode_appliance=$(
    cd "$GHR" || exit 1
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    set +e
    export PATH="$GHR/bin:$PATH" GH_STUB_BODY='{"message":"Not Found"}' GH_STUB_NOCODE=1 PITHEAD_APPLIANCE=1
    gh_release_fetch p2pool-starter-stack/pithead
    printf '%s|%s' "$?" "$GH_RELEASE_HINT"
)
assert_eq "appliance unparseable response is still a failure" "${gh_nocode_appliance%%|*}" "1"
assert_contains "and reads as an unreadable shape" "$gh_nocode_appliance" "answered in a shape this cannot read"
assert_contains "and points at the dashboard instead of a shell" "$gh_nocode_appliance" "Retry from the dashboard"
case "$gh_nocode_appliance" in
*"./pithead"*) bad "appliance unparseable-response hint names no CLI verb" "still says: $gh_nocode_appliance" ;;
*) ok "appliance unparseable-response hint names no CLI verb" ;;
esac

gh_tf_diy=$(PITHEAD_APPLIANCE=0 gh_fetch 000 '' 1)
assert_contains "DIY transport-failure advice is unchanged" "$gh_tf_diy" "Check './pithead doctor' and retry."
gh_nocode_diy=$(
    cd "$GHR" || exit 1
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    set +e
    export PATH="$GHR/bin:$PATH" GH_STUB_BODY='{"message":"Not Found"}' GH_STUB_NOCODE=1 PITHEAD_APPLIANCE=0
    gh_release_fetch p2pool-starter-stack/pithead
    printf '%s' "$GH_RELEASE_HINT"
)
assert_contains "DIY unparseable-response advice is unchanged" "$gh_nocode_diy" "Check './pithead doctor' and retry."

echo "== black-box: control upgrade verb (#59) =="
UPG="$SANDBOX/upgrade59"
UPGREQS="$UPG/data/control/requests"
UPGRESULTS="$UPG/data/control/results"
UPGAUDIT="$UPG/data/control/audit/control.log"
mkdir -p "$UPGREQS" "$UPG/data/control/staged" "$UPGRESULTS" "$UPG/data/control/audit"
cp "$STACK" "$UPG/pithead"
make_stubs "$UPG/bin"
command -v gtar >/dev/null 2>&1 && ln -sf "$(command -v gtar)" "$UPG/bin/tar"
write_fake_docker "$UPG/bin"
printf '1.3.1' >"$UPG/VERSION"
printf '{}' >"$UPG/config.json"
mkdir -p "$UPG/build/monero" "$UPG/build/tari" "$UPG/build/tari-wallet"
printf 'stale-monero-template-v1.3.1\n' >"$UPG/build/monero/bitmonero.conf.template"
printf 'stale-tari-template-v1.3.1\n' >"$UPG/build/tari/config.toml.template"
printf 'stale-tari-wallet-entry-v1.3.1\n' >"$UPG/build/tari-wallet/entrypoint.sh"
printf 'leftover-from-a-removed-mount\n' >"$UPG/build/monero/leftover.conf"
cat >"$UPG/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >>"${CURL_LOG:-/dev/null}"
[ "${CURL_FAIL:-}" = "1" ] && exit 22
url="${*: -1}"
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
case "$url" in
# The release lookup reads the body AND the status now (#1081), so the stub has to answer in the
# shape `-w '\n%{http_code}'` produces. GH_STUB_CODE lets a test drive a non-2xx through the real
# control path; unset means the ordinary 200.
*api.github.com*)
    cat "${CURL_API_RESPONSE:?}"
    printf '\n%s' "${GH_STUB_CODE:-200}"
    ;;
*releases/download/*.sig) cp "${CURL_SIG:?}" "$out" ;;
*releases/download/*) cp "${CURL_BUNDLE:?}" "$out" ;;
*) exit 22 ;;
esac
EOF
chmod +x "$UPG/bin/curl"
UPGB="$SANDBOX/upgrade59-bundle"
mkdir -p "$UPGB/pithead/build/monero" "$UPGB/pithead/build/tari" "$UPGB/pithead/build/tari-wallet"
cat >"$UPGB/pithead/pithead" <<'EOF'
#!/usr/bin/env bash
echo "new-pithead $*" >>upgrade-invocations.log
[ "${NEW_PITHEAD_FAIL:-}" = "1" ] && exit 1
exit 0
EOF
chmod +x "$UPGB/pithead/pithead"
printf '9.9.9' >"$UPGB/pithead/VERSION"
printf 'new-monero-template-v9.9.9\n' >"$UPGB/pithead/build/monero/bitmonero.conf.template"
printf 'new-tari-template-v9.9.9\n' >"$UPGB/pithead/build/tari/config.toml.template"
printf 'new-tari-wallet-entry-v9.9.9\n' >"$UPGB/pithead/build/tari-wallet/entrypoint.sh"
tar -czf "$UPGB/bundle.tar.gz" -C "$UPGB" pithead
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel"}' >"$UPGB/api.json"
seed_upgrade_env() {
    cat >"$UPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=$1
CONTROL_DIR=$UPG/data/control
NETWORK_PREFIX=10.9.0
EOF
}
urun() {
    (cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" \
        ./pithead control-run-pending 2>&1)
}
upgrade_intent() {
    if [ "$#" -ge 2 ]; then
        printf '{"id":"%s","action":"upgrade","actor":"admin","version":"%s"}\n' "$1" "$2" >"$UPGREQS/$1.json"
    else
        printf '{"id":"%s","action":"upgrade","actor":"admin"}\n' "$1" >"$UPGREQS/$1.json"
    fi
}
UUPG="66666666-6666-4666-8666-666666666666"
reset_upgrade_state() {
    cp "$STACK" "$UPG/pithead"
    printf '1.3.1' >"$UPG/VERSION"
    rm -f "$UPG/data/control/staged/.upgrade-stamp" "$UPGRESULTS/$UUPG.json" "$UPG/upgrade-invocations.log"
    rm -f "$UPG"/config.json.bak-upgrade-* "$UPG"/.env.bak-upgrade-*
    : >"$UPG/curl.log"
}

printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$REQS/$UUPG.json"
run_pending >/dev/null
assert_eq "upgrade on a source checkout is rejected" "$(jq -r '.status' "$RESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "source-checkout refusal points at git pull" "$(jq -r '.error' "$RESULTS/$UUPG.json" 2>/dev/null)" "git pull"
rm -f "$RESULTS/$UUPG.json"

seed_upgrade_env false
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
out="$(urun)"
assert_rc "upgrade runner refuses when the channel is off" "$?" "1"
assert_contains "channel-off refusal names the flag" "$out" "not enabled"
[ -f "$UPGREQS/$UUPG.json" ] && ok "channel-off intent left unclaimed" || bad "channel-off intent left unclaimed" "claimed"
[ ! -f "$UPGRESULTS/$UUPG.json" ] && ok "channel-off intent gets no result" || bad "channel-off intent gets no result" "result written"
rm -f "$UPGREQS/$UUPG.json"
seed_upgrade_env true

reset_upgrade_state
ln -sf "$(command -v jq)" "$UPG/bin/jq"
write_unreachable_docker "$UPG/nodocker"
ln -sf "$(command -v jq)" "$UPG/nodocker/jq"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/nodocker:/usr/bin:/bin" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
rm -f "$UPG/bin/jq"
assert_eq "upgrade without a runnable verifier is rejected on a key-less install" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "verifier-missing refusal names docker" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "docker is not available"
assert_eq "verifier-missing refusal dials nothing" "$(cat "$UPG/curl.log" 2>/dev/null)" ""
assert_eq "verifier-missing refusal extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
assert_eq "verifier-missing refusal claims no throttle" "$(ls "$UPG/data/control/staged/.upgrade-stamp" 2>/dev/null)" ""

reset_upgrade_state
upgrade_intent "$UUPG" 'v9.9.9;curl evil.tld'
urun >/dev/null
assert_eq "shell-metacharacter version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "malformed-version rejection names the field" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "version"
assert_eq "no network dial for a malformed version" "$(cat "$UPG/curl.log" 2>/dev/null)" ""
reset_upgrade_state
upgrade_intent "$UUPG"
urun >/dev/null
assert_eq "missing version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_eq "no network dial for a missing version" "$(cat "$UPG/curl.log" 2>/dev/null)" ""

reset_upgrade_state
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9","target":"evil.tld/img:tag"}\n' "$UUPG" >"$UPGREQS/$UUPG.json"
urun >/dev/null
assert_contains "upgrade intent smuggling a target is rejected" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "unexpected keys"

reset_upgrade_state
upgrade_intent "$UUPG" "v1.9.9"
urun >/dev/null
assert_eq "container-proposed non-latest version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "forged-version rejection names the real latest" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "v9.9.9"
assert_eq "forged version downloads no bundle" "$(grep -c 'releases/download' "$UPG/curl.log" || true)" "0"
assert_eq "forged version leaves the install untouched" "$(cat "$UPG/VERSION")" "1.3.1"
upgrade_intent "$UUPG" "v1.9.9"
urun >/dev/null
assert_contains "a non-latest attempt still claims the throttle" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "less than 10 minutes"

reset_upgrade_state
printf '{"tag_name":"v1.3.1","html_url":"https://example.invalid/rel"}' >"$UPGB/api-same.json"
upgrade_intent "$UUPG" "v1.3.1"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api-same.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "same-version upgrade is rejected as up to date" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "already up to date"

reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_FAIL=1 CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "unreachable release API rejects the upgrade" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "could not reach"
reset_upgrade_state
printf '{"tag_name":"main","html_url":"https://example.invalid/rel"}' >"$UPGB/api-bad.json"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api-bad.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "non-semver API tag rejects the upgrade" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "no usable release tag"

reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/missing.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "failed bundle download reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "download failure says the stack keeps running" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "keeps running"
assert_eq "download failure extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"

reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" NEW_PITHEAD_FAIL=1 CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "failed upgrade run reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_not_contains "failed upgrade log does not contain host-only recovery" "$(jq -r '.log' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "./pithead upgrade"
assert_eq "failed upgrade separates recovery and omits error" "$(jq -r '[(.recovery | contains("./pithead upgrade")), has("error")] | @tsv' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" $'true\tfalse'
assert_contains "failed upgrade audited" "$(cat "$UPGAUDIT" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"failed\""
upg_bak="$(jq -r '.backup // ""' "$UPGRESULTS/$UUPG.json" 2>/dev/null)"
assert_contains "failed in-place upgrade names the pre-upgrade copies (#637)" "$upg_bak" ".bak-upgrade-"
upg_bak_cfg="${upg_bak%% *}"
[ -n "$upg_bak_cfg" ] && [ -f "$upg_bak_cfg" ] && ok "the named config.json copy exists (#637)" ||
    bad "the named config.json copy exists (#637)" "missing: $upg_bak_cfg"

reset_upgrade_state
: >"$UPGAUDIT"
upgrade_intent "$UUPG" "v9.9.9"
out="$(urun)"
assert_rc "runner exits 0 on a valid upgrade" "$?" "0"
assert_eq "upgrade result status" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "upgrade result carries the host-derived version" "$(jq -r '.version' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "v9.9.9"
assert_eq "bundle extracted over the install" "$(cat "$UPG/VERSION")" "9.9.9"
assert_contains "the NEW pithead ran the upgrade" "$(cat "$UPG/upgrade-invocations.log" 2>/dev/null)" "new-pithead upgrade"
assert_eq "both GitHub dials went over Tor SOCKS" "$(grep -c -- '--socks5-hostname 10.9.0.25:9050' "$UPG/curl.log")" "2"
assert_eq "no cosign.pub -> no signature dial (documented fallback)" "$(grep -c '\.sig' "$UPG/curl.log" || true)" "0"
assert_contains "upgrade start audited" "$(cat "$UPGAUDIT")" "\"action\":\"upgrade\",\"status\":\"started\""
assert_contains "upgrade completion audited" "$(cat "$UPGAUDIT")" "\"action\":\"upgrade\",\"status\":\"upgraded\""
assert_eq "build/* new content lands (monero template)" "$(cat "$UPG/build/monero/bitmonero.conf.template" 2>/dev/null)" "new-monero-template-v9.9.9"
assert_eq "build/* new content lands (tari template)" "$(cat "$UPG/build/tari/config.toml.template" 2>/dev/null)" "new-tari-template-v9.9.9"
assert_eq "build/* new content lands (tari-wallet entrypoint)" "$(cat "$UPG/build/tari-wallet/entrypoint.sh" 2>/dev/null)" "new-tari-wallet-entry-v9.9.9"
assert_eq "a stale build/* file absent from the new bundle survives the merge" "$(cat "$UPG/build/monero/leftover.conf" 2>/dev/null)" "leftover-from-a-removed-mount"
if [ ! -e "$UPG/data/control/staged/.$UUPG.tar.gz" ] && [ ! -e "$UPG/data/control/staged/.$UUPG.log" ]; then
    ok "no staged bundle/log residue after a successful upgrade"
else
    bad "no staged bundle/log residue after a successful upgrade" "leftover staging file present"
fi
upg_bak_env="$(ls "$UPG"/.env.bak-upgrade-* 2>/dev/null | head -1)"
[ -n "$upg_bak_env" ] && ok "in-place upgrade keeps a pre-upgrade .env copy (#637)" ||
    bad "in-place upgrade keeps a pre-upgrade .env copy (#637)" "no .env.bak-upgrade-* in $UPG"
assert_contains "the .env copy holds the pre-upgrade content (#637)" "$(cat "$upg_bak_env" 2>/dev/null)" "DEPLOYMENT_COMPLETED=true"
upg_bak_cfg2="$(ls "$UPG"/config.json.bak-upgrade-* 2>/dev/null | head -1)"
assert_eq "the config.json copy holds the pre-upgrade content (#637)" "$(cat "$upg_bak_cfg2" 2>/dev/null)" "{}"

reset_upgrade_state
printf '%s\n' '#!/usr/bin/env bash' 'case "${*: -1}" in */.bak-upgrade.*) exit 1 ;; esac' 'exec /bin/cp "$@"' >"$UPG/bin/cp"
chmod +x "$UPG/bin/cp"
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_eq "failed snapshot fails the upgrade (#637)" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "snapshot refusal names the missing restore point (#637)" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "restore point"
assert_eq "failed snapshot extracts nothing (#637)" "$(cat "$UPG/VERSION")" "1.3.1"
[ -z "$(ls "$UPG"/.bak-upgrade.* 2>/dev/null)" ] && ok "failed snapshot leaves no mktemp residue (#637)" ||
    bad "failed snapshot leaves no mktemp residue (#637)" "leftover temp file"
rm -f "$UPG/bin/cp"

reset_upgrade_state
cat >"$UPG/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "+%Y%m%d-%H%M%S" ]; then echo "20990101-000000"; else exec /bin/date "$@"; fi
EOF
chmod +x "$UPG/bin/date"
printf 'victim-untouched' >"$UPG/victim"
ln -s "$UPG/victim" "$UPG/config.json.bak-upgrade-20990101-000000"
for bakstamp in 20200101-000000 20200102-000000 20200103-000000; do
    printf 'stale' >"$UPG/.env.bak-upgrade-$bakstamp"
    printf 'stale' >"$UPG/config.json.bak-upgrade-$bakstamp"
done
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_eq "planted symlink at the snapshot name is not written through (#637)" "$(cat "$UPG/victim")" "victim-untouched"
if [ ! -L "$UPG/config.json.bak-upgrade-20990101-000000" ] && [ -f "$UPG/config.json.bak-upgrade-20990101-000000" ]; then
    ok "the snapshot replaced the planted entry with a regular file (#637)"
else
    bad "the snapshot replaced the planted entry with a regular file (#637)" "still a symlink or missing"
fi
assert_eq "snapshots pruned to the newest three .env copies (#637)" "$(ls -1 "$UPG"/.env.bak-upgrade-* 2>/dev/null | wc -l | tr -d ' ')" "3"
assert_eq "snapshots pruned to the newest three config.json copies (#637)" "$(ls -1 "$UPG"/config.json.bak-upgrade-* 2>/dev/null | wc -l | tr -d ' ')" "3"
[ ! -e "$UPG/.env.bak-upgrade-20200101-000000" ] && ok "the oldest .env snapshot was pruned (#637)" ||
    bad "the oldest .env snapshot was pruned (#637)" "still present"
rm -f "$UPG/bin/date" "$UPG/victim"
reset_upgrade_state

reset_upgrade_state
mkdir -p "$UPGB/rollback/pithead"
cp "$UPGB/pithead/pithead" "$UPGB/rollback/pithead/pithead"
printf '1.0.0' >"$UPGB/rollback/pithead/VERSION"
tar -czf "$UPGB/rollback.tar.gz" -C "$UPGB/rollback" pithead
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
    CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/rollback.tar.gz" \
    ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "version-mismatched (rollback) bundle is refused" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "rollback refusal names the mismatch" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rollback"
assert_eq "rollback bundle extracts nothing (VERSION untouched)" "$(cat "$UPG/VERSION")" "1.3.1"
assert_eq "rollback bundle never ran a new pithead" "$(cat "$UPG/upgrade-invocations.log" 2>/dev/null || echo none)" "none"

reset_upgrade_state
mkdir -p "$UPGB/noversion/pithead"
cp "$UPGB/pithead/pithead" "$UPGB/noversion/pithead/pithead"
tar -czf "$UPGB/noversion.tar.gz" -C "$UPGB/noversion" pithead
UUPG2="77777777-7777-4777-8777-777777777777"
upgrade_intent "$UUPG" "v9.9.9"
sleep 1
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG2" >"$UPGREQS/$UUPG2.json"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
    CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/noversion.tar.gz" \
    ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "bundle missing pithead/VERSION reports failed (not stuck running)" \
    "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "missing-VERSION failure names the cause" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "missing pithead/VERSION"
assert_eq "missing-VERSION bundle extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
[ -z "$(find "$UPG/data/control" -maxdepth 1 -name '.claim.*' 2>/dev/null)" ] &&
    ok "missing-VERSION failure releases its claim" || bad "missing-VERSION failure releases its claim" "claim file left behind"
[ -f "$UPGRESULTS/$UUPG2.json" ] &&
    ok "the rest of the queue is not abandoned (second intent still processed)" ||
    bad "the rest of the queue is not abandoned (second intent still processed)" "no result written for the second intent"
rm -f "$UPGRESULTS/$UUPG2.json" "$UPGREQS/$UUPG2.json"

cp "$STACK" "$UPG/pithead"
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_contains "immediate second upgrade attempt is throttled" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "less than 10 minutes"
reset_upgrade_state

echo "== black-box: control upgrade extracts to a fresh version dir (#629) =="
VROOT="$SANDBOX/deploy629"
VUPG="$VROOT/pithead-v1.3.1"
VNEW="$VROOT/pithead-v9.9.9"
mkdir -p "$VUPG/data/control/requests" "$VUPG/data/control/staged" "$VUPG/data/control/results" \
    "$VUPG/data/control/audit" "$VUPG/data/clearnet-state" "$VROOT/data/monero"
cp "$STACK" "$VUPG/pithead"
printf '1.3.1' >"$VUPG/VERSION"
printf '{}' >"$VUPG/config.json"
printf 'clearnet-marker' >"$VUPG/data/clearnet-state/monero.synced"
seed_v629_env() {
    cat >"$VUPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$VUPG/data/control
NETWORK_PREFIX=10.9.0
MONERO_DATA_DIR=$VROOT/data/monero
TARI_DATA_DIR=$VROOT/data/tari
P2POOL_DATA_DIR=$VROOT/data/p2pool
TOR_DATA_DIR=$VROOT/data/tor
DASHBOARD_DATA_DIR=$VROOT/data/dashboard
EOF
}
seed_v629_env
vrun() {
    (cd "$VUPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$VUPG/curl.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" \
        env "$@" ./pithead control-run-pending 2>&1)
}
reset_v629_state() {
    cp "$STACK" "$VUPG/pithead"
    printf '1.3.1' >"$VUPG/VERSION"
    rm -f "$VUPG/data/control/staged/.upgrade-stamp" "$VUPG/data/control/results/$UUPG.json"
    rm -f "$VUPG"/config.json.bak-upgrade-* "$VUPG"/.env.bak-upgrade-*
    rm -rf "$VNEW"
}

printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
vrun >/dev/null
assert_eq "fresh-dir upgrade result status (old spool)" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "fresh-dir upgrade result status (new spool)" "$(jq -r '.status' "$VNEW/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "new version dir holds the new release" "$(cat "$VNEW/VERSION" 2>/dev/null)" "9.9.9"
assert_eq "old version dir still holds the old release (rollback preserved)" "$(cat "$VUPG/VERSION")" "1.3.1"
cmp -s "$VUPG/pithead" "$STACK" && ok "old dir's pithead untouched by the extraction" ||
    bad "old dir's pithead untouched by the extraction" "the running script was overwritten"
assert_contains "the NEW pithead ran the upgrade from the NEW dir" "$(cat "$VNEW/upgrade-invocations.log" 2>/dev/null)" "new-pithead upgrade"
[ -f "$VNEW/config.json" ] && ok "config.json seeded into the new dir" || bad "config.json seeded into the new dir" "missing"
assert_contains "rendered .env seeded into the new dir" "$(cat "$VNEW/.env" 2>/dev/null)" "DEPLOYMENT_COMPLETED=true"
assert_eq "clearnet sync markers carried over" "$(cat "$VNEW/data/clearnet-state/monero.synced" 2>/dev/null)" "clearnet-marker"
assert_contains "fresh-dir upgrade audited in the old spool" "$(cat "$VUPG/data/control/audit/control.log" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"upgraded\""
assert_contains "fresh-dir upgrade audited in the new spool" "$(cat "$VNEW/data/control/audit/control.log" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"upgraded\""
assert_contains "fresh-dir result names the old dir as the rollback copy (#637)" \
    "$(jq -r '.rollback // ""' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "/deploy629/pithead-v1.3.1"
[ -z "$(ls "$VUPG"/.env.bak-upgrade-* 2>/dev/null)" ] &&
    ok "fresh-dir path takes no file snapshots — the old dir IS the restore point (#637)" ||
    bad "fresh-dir path takes no file snapshots — the old dir IS the restore point (#637)" "found .bak-upgrade-* in $VUPG"

reset_v629_state
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
vrun NEW_PITHEAD_FAIL=1 >/dev/null
assert_eq "failed fresh-dir upgrade reports failed" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "failed"
assert_not_contains "failed fresh-dir log does not contain host-only recovery" "$(jq -r '.log' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "./pithead upgrade"
assert_eq "failed fresh-dir recovery points at the new dir and omits error" "$(jq -r '[(.recovery | contains("/deploy629/pithead-v9.9.9 && ./pithead upgrade")), has("error")] | @tsv' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" $'true\tfalse'
assert_eq "failed fresh-dir upgrade leaves the old install intact" "$(cat "$VUPG/VERSION")" "1.3.1"
assert_eq "failed fresh-dir upgrade wrote the result to the new spool too" "$(jq -r '.status' "$VNEW/data/control/results/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "failed fresh-dir result still names the rollback dir (#637)" \
    "$(jq -r '.rollback // ""' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "/deploy629/pithead-v1.3.1"

reset_v629_state
mkdir -p "$VUPG/data/monero"
cat >"$VUPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$VUPG/data/control
NETWORK_PREFIX=10.9.0
MONERO_DATA_DIR=$VUPG/data/monero
EOF
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_eq "data-inside-install falls back to in-place upgrade" "$(cat "$VUPG/VERSION")" "9.9.9"
[ ! -e "$VNEW" ] && ok "data-inside-install creates no sibling version dir" ||
    bad "data-inside-install creates no sibling version dir" "$VNEW exists"
assert_contains "in-place fallback names the stranded data dir" "$out" "MONERO_DATA_DIR resolves inside the install dir"
assert_eq "in-place fallback still upgrades" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
[ -n "$(ls "$VUPG"/.env.bak-upgrade-* 2>/dev/null)" ] &&
    ok "in-place fallback keeps the pre-upgrade config/.env copies (#637)" ||
    bad "in-place fallback keeps the pre-upgrade config/.env copies (#637)" "no .bak-upgrade-* in $VUPG"
seed_v629_env

reset_v629_state
mkdir -p "$VNEW"
printf 'not-ours' >"$VNEW/marker"
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_contains "pre-existing target dir falls back to in-place" "$out" "already exists"
assert_eq "pre-existing target dir is never written into" "$(
    cat "$VNEW/marker" 2>/dev/null
    ls "$VNEW" | wc -l | tr -d ' '
)" "not-ours1"
assert_eq "pre-existing target still upgrades in place" "$(cat "$VUPG/VERSION")" "9.9.9"
reset_v629_state
mkdir -p "$VROOT/plant"
ln -s "$VROOT/plant" "$VNEW"
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_contains "planted symlink at the target falls back to in-place" "$out" "already exists"
[ -z "$(ls -A "$VROOT/plant" 2>/dev/null)" ] && ok "planted symlink is not followed (nothing extracted through it)" ||
    bad "planted symlink is not followed (nothing extracted through it)" "files appeared behind the symlink"
rm -f "$VNEW"
seed_v629_env

echo "== black-box: control upgrade verifies the bundle signature (#376) =="
write_fake_docker "$UPG/bin"
printf 'fake release public key' >"$UPG/cosign.pub"
printf 'fake signature' >"$UPGB/bundle.sig"
usign() {
    (cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" COSIGN_LOG="$UPG/cosign.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/bundle.sig" \
        env "$@" ./pithead control-run-pending 2>&1)
}

: >"$UPG/cosign.log"
upgrade_intent "$UUPG" "v9.9.9"
usign >/dev/null
assert_eq "signed bundle with a valid signature upgrades" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "signature fetched over Tor SOCKS" "$(grep -c -- '--socks5-hostname 10.9.0.25:9050.*pithead\.tar\.gz\.sig' "$UPG/curl.log")" "1"
assert_contains "bundle verified against the existing key, no Rekor" \
    "$(cat "$UPG/cosign.log")" "verify-blob --key cosign.pub --signature"
reset_upgrade_state
: >"$UPG/cosign.log"
upgrade_intent "$UUPG" "v9.9.9"
usign COSIGN_RC=1 >/dev/null
assert_eq "bad bundle signature reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "bad-signature failure says verification FAILED" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "verification FAILED"
assert_eq "bad signature extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
[ ! -f "$UPG/upgrade-invocations.log" ] && ok "bad signature never runs the new pithead" || bad "bad signature never runs the new pithead" "it ran"

reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/missing.sig" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "missing signature asset reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "missing-signature failure names the asset" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "no bundle signature"
assert_eq "missing signature extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"

reset_upgrade_state
write_unreachable_docker "$UPG/nodocker"
ln -sf "$(command -v jq)" "$UPG/nodocker/jq"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/nodocker:/usr/bin:/bin" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/bundle.sig" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "pubkey without a runnable verifier rejects the upgrade" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "verifier-missing rejection names docker" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "docker is not available"
assert_eq "verifier-missing refusal downloads no bundle" "$(grep -c 'releases/download' "$UPG/curl.log" || true)" "0"
rm -f "$UPG/cosign.pub" "$UPG/nodocker/jq"
reset_upgrade_state

control_config main
"$C/bin/docker" >/dev/null 2>&1 || true
sed -i.bak 's/"control":{"enabled":true}/"control":{"enabled":false}/' "$C/config.json" 2>/dev/null || true
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
out="$(run_pending)"
assert_rc "runner refuses when the channel is disabled" "$?" "1"
assert_contains "runner disabled message" "$out" "not enabled"
