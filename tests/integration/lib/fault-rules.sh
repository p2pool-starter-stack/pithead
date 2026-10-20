# shellcheck shell=bash
# Every fault leg tags its kernel rules with this prefix so any run can find and remove them.
FAULT_RULE_PREFIX="pithead-e2e-fault-"
_FAULT_RULES_FOREIGN_TRAP=""

fault_rules_snippet() {
    cat <<'SCAN'
for id in $(docker ps -q 2>/dev/null); do
    info=$(docker inspect -f '{{.State.Pid}} {{.Name}}' "$id" 2>/dev/null) || continue
    pid=${info%% *}
    name=${info#* }
    name=${name#/}
    [ "${pid:-0}" -gt 0 ] 2>/dev/null || continue
    i=0
    while [ "$i" -lt 6 ]; do
        i=$((i + 1))
        rule=$(sudo -n nsenter -t "$pid" -n iptables -S 2>/dev/null | tr -d '"' | grep -m1 -E -- "^-A .* --comment ${prefix}") || break
        tag=$(printf '%s\n' "$rule" | grep -oE -- "${prefix}[A-Za-z0-9_-]*" | head -n 1)
        set -f
        set -- ${rule#-A }
        set +f
        if [ "$i" -lt 6 ] && sudo -n nsenter -t "$pid" -n iptables -D "$@" >/dev/null 2>&1; then
            echo "removed $name $tag"
        else
            echo "left $name $tag"
            break
        fi
    done
done
SCAN
}

# Removes every tagged rule from every running container's network namespace; never fails.
fault_rules_clear_all() {
    local line
    while IFS= read -r line; do
        case "$line" in
        removed\ *) it_step "removed fault rule: ${line#removed }" ;;
        left\ *) it_warn "fault rule could not be removed: ${line#left }" ;;
        esac
    done < <(rx "prefix=$(quote_arg "$FAULT_RULE_PREFIX"); $(fault_rules_snippet)" </dev/null 2>/dev/null)
    return 0
}

fault_rules_exit() {
    local rc=$?
    fault_rules_clear_all
    [ -z "$_FAULT_RULES_FOREIGN_TRAP" ] || eval "$_FAULT_RULES_FOREIGN_TRAP"
    return "$rc"
}

# A bare EXIT trap also runs on TERM and INT; naming the signals would let the run resume (#1401).
fault_rules_trap_arm() {
    local cur
    cur="$(trap -p EXIT)"
    case "$cur" in *fault_rules_exit*) return 0 ;; esac
    _FAULT_RULES_FOREIGN_TRAP=""
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _FAULT_RULES_FOREIGN_TRAP="${parsed[2]}"
    fi
    trap fault_rules_exit EXIT
}

fault_rules_trap_disarm() {
    case "$(trap -p EXIT)" in *fault_rules_exit*) ;; *) return 0 ;; esac
    trap - EXIT
    # shellcheck disable=SC2064  # restore the saved trap text as it was, expanded now on purpose
    [ -z "$_FAULT_RULES_FOREIGN_TRAP" ] || trap "$_FAULT_RULES_FOREIGN_TRAP" EXIT
    _FAULT_RULES_FOREIGN_TRAP=""
}
