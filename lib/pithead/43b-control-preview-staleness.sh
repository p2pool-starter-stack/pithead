# Digest of the live config.json: the revision a preview is staged against (#3352).
control_live_config_sum() {
    sha256sum "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f1
}

# True when config.json moved since the preview recorded its digest in <base-file>. The preview was
# a diff against one revision; if another tab or `pithead apply` changed it since, committing the
# staged whole-document copy would silently replace that change. A staged copy with no digest file
# (hand-placed, never previewed) is not judged here.
control_preview_stale() { # <base-file>
    [ -f "$1" ] && [ "$(cat "$1")" != "$(control_live_config_sum)" ]
}

# control_commit's precheck: no staged copy, an expired one (10 minutes), or a stale one. On any of
# these it rejects, clears the copy and returns 0; 1 means the commit may go on.
control_commit_unusable() { # <id> <actor> <control-dir>
    local id="$1" actor="$2" cdir="$3" err=""
    local staged="$cdir/staged/$id.json" basef="$cdir/staged/.$id.base"
    if [ ! -f "$staged" ]; then
        err="no staged intent for this id — preview first"
    elif [ -z "$(find "$staged" -mmin -10 2>/dev/null)" ]; then
        err="staged intent expired (older than 10 minutes) — preview again"
    elif control_preview_stale "$basef"; then
        err="the configuration changed after this preview was made — preview again"
    else
        return 1
    fi
    rm -f "$staged" "$basef" "${staged}.confirmed"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
    control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$err" '{status:"rejected",error:$e,ts:(now|floor)}')"
}
