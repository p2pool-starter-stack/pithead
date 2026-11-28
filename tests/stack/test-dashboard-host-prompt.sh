# shellcheck shell=bash
: "${STACK_SUITE:?run tests/stack/run.sh}"
echo "== unit: interactive dashboard hostname prompt validates its answer (#4463) =="
DHP="$SANDBOX/dhp"
mkdir -p "$DHP"
cat >"$DHP/drive.sh" <<'DRV'
#!/usr/bin/env bash
cd "$1" || exit 1
# shellcheck disable=SC1090
source "$2" 2>/dev/null
set +e
log() { :; }
DASHBOARD_HOST=""
PRESERVED_HOST_IP="$3"
resolve_dashboard_host interactive
printf 'HOST=%s\n' "$HOST_IP"
DRV
dhp_ask() {
    printf '%b' "$1" | timeout 30 script -qec "bash $DHP/drive.sh $DHP $STACK '${2:-box.lan}'" /dev/null 2>&1 | tr -d '\r'
    return "${PIPESTATUS[1]}"
}
out=$(dhp_ask 'my host {x}\nmy.box.lan\n')
assert_rc "a valid answer after an invalid one succeeds" "$?" "0"
assert_contains "the invalid answer is named in a clear message" "$out" "'my host {x}' is not a valid hostname or IP address"
assert_contains "the valid second answer is used" "$out" "HOST=my.box.lan"
out=$(dhp_ask 'https://box.lan\n')
assert_rc "end of input after a refused URL takes the default" "$?" "0"
assert_contains "the URL is refused" "$out" "'https://box.lan' is not a valid hostname or IP address"
assert_contains "the URL never becomes the hostname" "$out" "HOST=box.lan"
out=$(dhp_ask '\n')
assert_rc "an empty answer succeeds" "$?" "0"
assert_contains "an empty answer takes the default" "$out" "HOST=box.lan"
out=$(dhp_ask '')
assert_rc "end of input still takes the default" "$?" "0"
assert_contains "the default is used at end of input" "$out" "HOST=box.lan"
out=$(dhp_ask '' 'bad host')
assert_rc "end of input with an invalid default exits non-zero" "$?" "1"
assert_contains "the invalid default is named" "$out" "'bad host' is not a valid hostname or IP address"
case "$out" in *HOST=*) bad "an invalid default never becomes the hostname" "$out" ;; *) ok "an invalid default never becomes the hostname" ;; esac
