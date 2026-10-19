# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

run_backup_ownership() {
    local before="$IT_FAIL" overlay probe_rc=0 cleanup_rc=0 order step surface expected
    local probe="$HERE/tools/backup-ownership-probe.py" output="$OUT_DIR/backup-ownership.log"
    if ! rx 'python3 - --cleanup' --stdin <"$probe" >"$output" 2>&1; then
        it_fail "prior backup ownership fixture restored before apply (#3084)" "bounded cleanup replay failed"
        return 1
    fi
    overlay="$(printf '%s' "$BASELINE_CONFIG" | jq '.dashboard.secure=true | .dashboard.auth={username:"admin",password:"a tier4 backup passphrase"} | .dashboard.control={enabled:true}')"
    if push_config "$overlay" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 240; then
        rx 'python3 -' --stdin <"$probe" >>"$output" 2>&1 || probe_rc=$?
        rx 'python3 - --cleanup' --stdin <"$probe" >>"$output" 2>&1 || cleanup_rc=$?
        for order in gui-cli-gui cli-gui-gui; do
            step=0
            for surface in ${order//-/ }; do
                step=$((step + 1))
                expected="BACKUP_OWNERSHIP|$order|$step|$surface|pass"
                if grep -Fxq "$expected" "$output"; then
                    it_pass "$order archive $step: owner, mode, own-passphrase decryption and members (#3084)"
                else
                    it_fail "$order archive $step: owner, mode, own-passphrase decryption and members (#3084)" "live dashboard/control/CLI probe did not prove this archive"
                fi
            done
        done
        if [ "$probe_rc" -eq 0 ] && [ "$cleanup_rc" -eq 0 ] &&
            grep -Fxq 'BACKUP_OWNERSHIP|restoration|pass' "$output"; then
            it_pass "GUI backup followed by non-root CLI backup preserves the operator's backup directory (#3363)"
        else
            it_fail "GUI backup followed by non-root CLI backup preserves the operator's backup directory (#3363)" "probe or bounded cleanup failed; retained protocol in backup-ownership.log"
        fi
    else
        it_fail "live backup ownership fixture enabled (#3084)" "control-enabled apply or readiness failed"
    fi
    if [ "$cleanup_rc" -ne 0 ]; then
        it_fail "backup ownership cleanup settled before baseline restoration (#3084)" "root backup process or directory restoration did not settle"
        return 1
    fi
    if push_config "$BASELINE_CONFIG" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 240 && _remove_control_units; then
        it_pass "backup ownership proof restores the baseline configuration and control runner (#3084)"
    else
        it_fail "backup ownership proof restores the baseline configuration and control runner (#3084)" "baseline apply, readiness or owned-unit cleanup failed"
    fi
    [ "$IT_FAIL" -eq "$before" ]
}
