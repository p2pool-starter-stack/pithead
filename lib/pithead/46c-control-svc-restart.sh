readonly PITHEAD_SVC_RESTART_SERVICES="tor monerod wallet-rpc tari tari-wallet p2pool xmrig-proxy"
readonly PITHEAD_SVC_RESTART_COOLDOWN_S=120
readonly PITHEAD_SVC_RESTART_EX_GUARD=11
readonly PITHEAD_SVC_RESTART_EX_COOLDOWN=12

control_svc_restart_locked() ( # <control-dir> <service> <log-file>
    local cdir="$1" service="$2" logf="$3" stamp last now
    stamp="$cdir/svc-restart-$service"
    PITHEAD_LOCK_TIMEOUT=0 mutation_lock_acquire svc-restart
    lan_guard_ready || exit "$PITHEAD_SVC_RESTART_EX_GUARD"
    now=$(date +%s)
    last=0
    [ -f "$stamp" ] && [ ! -L "$stamp" ] && read -r last <"$stamp" || true
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ $((now - last)) -ge "$PITHEAD_SVC_RESTART_COOLDOWN_S" ] || exit "$PITHEAD_SVC_RESTART_EX_COOLDOWN"
    docker compose restart "$service" >"$logf" 2>&1 || exit 1
    printf '%s\n' "$now" >"$stamp"
)

control_svc_restart() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    local service found=0 c rc=0 logf="$cdir/staged/.$id.log" error
    service=$(jq -r 'if (.container | type) == "string" then .container else "" end' "$file")
    for c in $PITHEAD_SVC_RESTART_SERVICES; do
        [ "$service" = "$c" ] && found=1 && break
    done
    if [ "$found" -ne 1 ] || [ "$(jq -r 'keys | sort == ["action","actor","container","id"]' "$file")" != true ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",action:"svc-restart",error:"not a service this dashboard may restart.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "svc-restart" "rejected"
        return 0
    fi
    control_audit "$auditf" "$id" "$actor" "svc-restart" "started" "$service"
    mkdir -p "$cdir/staged"
    control_svc_restart_locked "$cdir" "$service" "$logf" || rc=$?
    case "$rc" in
    0)
        control_write_result "$results" "$id" "$(jq -n --arg s "$service" '{status:"applied",action:"svc-restart",container:$s,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "svc-restart" "applied" "$service"
        rm -f "$logf"
        return 0
        ;;
    "$PITHEAD_EX_LOCK_TIMEOUT") error="Another pithead operation is in progress; try again when it has finished." ;;
    "$PITHEAD_SVC_RESTART_EX_GUARD") error="The LAN-only source rule for the published ports is not in place, so a restart is refused. Run './pithead up' on the host." ;;
    "$PITHEAD_SVC_RESTART_EX_COOLDOWN") error="$service was restarted less than ${PITHEAD_SVC_RESTART_COOLDOWN_S}s ago; wait before restarting it again." ;;
    *)
        error="The restart of $service failed on the host: $(tail -c 1500 "$logf" 2>/dev/null | bundle_redact_log)"
        control_write_result "$results" "$id" "$(jq -n --arg s "$service" --arg e "$error" '{status:"failed",action:"svc-restart",container:$s,error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "svc-restart" "failed" "$service"
        rm -f "$logf"
        return 0
        ;;
    esac
    control_write_result "$results" "$id" "$(jq -n --arg s "$service" --arg e "$error" '{status:"rejected",action:"svc-restart",container:$s,error:$e,ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "svc-restart" "rejected" "$service"
    rm -f "$logf"
}
