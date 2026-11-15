# shellcheck shell=bash
SUPPORT_CONTROL_DIR=/data/pithead/data/control

_support_bundle_status() { dashboard_curl -sSk -m 8 "https://$ip/api/control/result?id=$1" 2>/dev/null | jq -r '.status // "pending"' 2>/dev/null; }

phase_provision_support_bundle() { # <ip> <dashboard-user> <dashboard-password>
    # shellcheck disable=SC2034 # DASH_USER/DASH_PASS: read by dashboard_curl via dynamic scope
    local ip="$1" DASH_USER="$2" DASH_PASS="$3" since until resp rid status deadline dl ex hdr fake n id
    since=$(_ssh 'date -u -d "-2 hours" +%Y-%m-%dT%H:%M:%SZ' | tr -d '\r\n')
    until=$(_ssh 'date -u +%Y-%m-%dT%H:%M:%SZ' | tr -d '\r\n')
    resp=$(dashboard_control_post support-bundle "$(jq -nc --arg s "$since" --arg u "$until" '{since:$s,until:$u}')" 45)
    rid=$(printf '%s' "$resp" | sed '$d' | jq -r '.id // ""' 2>/dev/null)
    if [ -z "$rid" ] || [ "$(printf '%s' "$resp" | tail -n1)" != 202 ]; then
        bad "support bundle: the control request with since and until was not accepted ($(printf '%s' "$resp" | tail -n1))"
        return
    fi
    deadline=$(($(date +%s) + 240))
    status=pending
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(_support_bundle_status "$rid")
        case "$status" in applied | failed | rejected) break ;; esac
        sleep 5
    done
    if [ "$status" != applied ]; then
        bad "support bundle: the control request ended as '$status', not applied"
        return
    fi
    ok "support-bundle control request with an explicit window is applied on the deployed stack (#4127)"
    ex=$(mktemp -d)
    hdr="$ex/headers"
    dl="$ex/bundle.zip"
    if dashboard_curl -fsSk -m 120 -D "$hdr" -o "$dl" "https://$ip/api/control/support-bundle-download?id=$rid" &&
        grep -qi '^content-disposition:.*support-bundle-[0-9T]*Z\.zip' "$hdr" &&
        python3 -I -m zipfile -e "$dl" "$ex/x" >/dev/null &&
        jq -e --arg s "$since" --arg u "$until" '.window.requested.since == $s and .window.requested.until == $u and (.files | map(.path) | index("journal/all.log") != null) and (.files | map(.path) | index("journal/kernel.log") != null)' "$ex/x/bundle/manifest.json" >/dev/null &&
        [ -s "$ex/x/bundle/journal/all.log" ]; then
        ok "the browser download route serves a readable zip whose manifest records the requested window (#4127)"
    else
        bad "support bundle: the download is not a zip with the requested window in its manifest"
    fi
    if _ssh "[ \"\$(stat -c %a $SUPPORT_CONTROL_DIR/results/$rid.zip)\" = 600 ] && ! ls $SUPPORT_CONTROL_DIR/results/$rid.tar.gz >/dev/null 2>&1"; then
        ok "the spool holds <id>.zip at mode 600 and no tarball (#4127)"
    else
        bad "support bundle: the spool archive is not a mode-600 <id>.zip"
    fi
    fake=""
    for n in 1 2 3; do
        id=$(_ssh 'cat /proc/sys/kernel/random/uuid' | tr -d '\r\n')
        fake="$fake $id"
        _ssh "cd $SUPPORT_CONTROL_DIR/results && cp $rid.zip $id.zip && printf '{\"status\":\"applied\",\"archive\":\"support-bundle-x.zip\",\"ts\":0}' >$id.json && touch -d '$((n + 2)) hours ago' $id.zip $id.json"
    done
    _ssh "cd $SUPPORT_CONTROL_DIR/results && touch -d '9 hours ago' $rid.zip $rid.json && systemctl start pithead-control.service"
    deadline=$(($(date +%s) + 60))
    while [ "$(date +%s)" -lt "$deadline" ] && _ssh "ls $SUPPORT_CONTROL_DIR/results/$rid.zip >/dev/null 2>&1"; do sleep 3; done
    if _ssh "! ls $SUPPORT_CONTROL_DIR/results/$rid.zip $SUPPORT_CONTROL_DIR/results/$rid.json >/dev/null 2>&1 && [ \"\$(ls $SUPPORT_CONTROL_DIR/results/*.zip | wc -l)\" -le 3 ]"; then
        ok "results retention prunes the oldest expired support-bundle zip with its result past the archive cap (#4127)"
    else
        bad "support bundle: the oldest expired zip survived the retention prune"
    fi
    for id in $fake; do _ssh "rm -f $SUPPORT_CONTROL_DIR/results/$id.zip $SUPPORT_CONTROL_DIR/results/$id.json"; done
    rm -rf "$ex"
}
