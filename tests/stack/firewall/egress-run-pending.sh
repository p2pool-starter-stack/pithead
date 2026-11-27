# shellcheck shell=bash
echo "== egress-run-pending claims every requests entry before it reads one =="
ERP=$(mktemp -d "$SANDBOX/egress-run.XXXXXX")
ERP_REQ="$ERP/data/control/requests"
ERP_ID=00000000-0000-4000-8000-0000000000e1
ERP_DIR_ID=00000000-0000-4000-8000-0000000000e2
ERP_LINK_ID=00000000-0000-4000-8000-0000000000e3
ERP_OLD_ID=00000000-0000-4000-8000-0000000000e4
mkdir -p "$ERP_REQ" "$ERP/outside/dir" "$ERP_REQ/empty.json" "$ERP_REQ/full.json" "$ERP_REQ/$ERP_DIR_ID.json" "$ERP_REQ/line"$'\n'"break.json"
printf 'keep\n' >"$ERP/outside/file.txt"
printf 'keep\n' >"$ERP/outside/dir/inner.txt"
chmod 640 "$ERP/outside/file.txt"
chmod 750 "$ERP/outside/dir"
printf 'x\n' >"$ERP_REQ/full.json/x"
printf 'x\n' >"$ERP_REQ/$ERP_DIR_ID.json/x"
printf 'x\n' >"$ERP_REQ/name.json"
ln -s "$ERP/missing" "$ERP_REQ/dangling.json"
ln -s "$ERP/outside/file.txt" "$ERP_REQ/to-file.json"
ln -s "$ERP/outside/dir" "$ERP_REQ/to-dir.json"
ln -s "$ERP/outside/dir" "$ERP_REQ/$ERP_LINK_ID.json"
printf '{"id":"%s","action":"egress-sync","chain":"monero"}\n' "$ERP_ID" >"$ERP_REQ/$ERP_ID.json"
mkdir -p "$ERP/data/control/.claim.egress.$ERP_OLD_ID" "$ERP/data/control/.claim.egress.$$"
printf 'x\n' >"$ERP/data/control/.claim.egress.$ERP_OLD_ID/x"
printf 'x\n' >"$ERP/data/control/.claim.egress.$$/x"
printf '{"id":"%s","action":"egress-sync","chain":"monero"}\n' "$ERP_OLD_ID" >"$ERP_REQ/$ERP_OLD_ID.json"
ERP_RC=$(
    cd "$ERP" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    egress_sync_refresh() { [ "$1" = monero ]; }
    egress_sync_run_pending
    printf 'first=%s ' "$?"
    egress_sync_run_pending
    printf 'empty=%s ' "$?"
    mv data/control/requests data/control/gone
    egress_sync_run_pending
    printf 'missing=%s' "$?"
    mv data/control/gone data/control/requests
)
erp_gone() { if [ -e "$ERP_REQ/$2" ] || [ -L "$ERP_REQ/$2" ]; then bad "$1" "still present"; else ok "$1"; fi; }
erp_gone "an empty folder with a non-UUID name is removed" empty.json
erp_gone "a non-empty folder with a non-UUID name is removed" full.json
erp_gone "a folder with a line break in its name is removed" "line"$'\n'"break.json"
erp_gone "a dangling link is removed" dangling.json
erp_gone "a link to a file is removed" to-file.json
erp_gone "a link to a folder is removed" to-dir.json
erp_gone "a regular file with a non-UUID name is removed" name.json
erp_gone "a folder with a UUID name leaves the requests folder" "$ERP_DIR_ID.json"
erp_gone "a link with a UUID name leaves the requests folder" "$ERP_LINK_ID.json"
assert_eq "no claim is left in the control folder" "$(find "$ERP/data/control" -maxdepth 1 -name '.claim.*' | wc -l | tr -d ' ')" "0"
assert_eq "the valid request beside them is applied" "$(jq -r .status "$ERP/data/control/results/$ERP_ID.json")" "applied"
assert_eq "a request whose claim name held an older folder is applied" "$(jq -r .status "$ERP/data/control/results/$ERP_OLD_ID.json")" "applied"
assert_eq "no result is written for the other entries" "$(find "$ERP/data/control/results" -type f | wc -l | tr -d ' ')" "2"
assert_eq "a linked file keeps its content and mode" "$(cat "$ERP/outside/file.txt") $(stat -c %a "$ERP/outside/file.txt")" "keep 640"
assert_eq "a linked folder keeps its file and mode" "$(cat "$ERP/outside/dir/inner.txt") $(stat -c %a "$ERP/outside/dir")" "keep 750"
assert_eq "return codes stay the same for a run, an empty and a missing requests folder" "$ERP_RC" "first=0 empty=0 missing=1"
