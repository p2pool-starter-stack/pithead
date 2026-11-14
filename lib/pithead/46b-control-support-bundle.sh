control_support_bundle() {
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    local stamp="$cdir/staged/.support-bundle-stamp"
    local raw hours arch rc=0 fname dest
    control_audit "$auditf" "$id" "$actor" "support-bundle" "started"
    if [ -n "$(find "$stamp" -mmin -1 2>/dev/null)" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"a support bundle was collected less than a minute ago — wait for the download window, then retry.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "support-bundle" "rejected"
        return 0
    fi
    raw=$(jq -r '.hours // ""' "$file")
    hours=$(bundle_support_clamp_hours "$raw")
    touch "$stamp" 2>/dev/null || true
    control_write_result "$results" "$id" "$(jq -n '{status:"running",ts:(now|floor)}')"
    arch=$(bundle_support_collect "$cdir/staged" "$hours") || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$arch" ] || [ ! -f "$arch" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"failed",error:"the host could not collect a support bundle — nothing was written.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "support-bundle" "failed"
        return 0
    fi
    fname=$(basename "$arch")
    dest="$results/$id.tar.gz"
    if ! mv -f "$arch" "$dest"; then
        rm -f "$arch"
        control_write_result "$results" "$id" "$(jq -n '{status:"failed",error:"the host collected the bundle but could not move it onto the download leg.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "support-bundle" "failed"
        return 0
    fi
    chown "$APP_UID:$APP_GID" "$dest" 2>/dev/null || true
    chmod 600 "$dest" 2>/dev/null || true
    control_write_result "$results" "$id" "$(jq -n --arg f "$fname" --argjson h "$hours" '{status:"applied",archive:$f,hours:$h,ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "support-bundle" "applied"
}
