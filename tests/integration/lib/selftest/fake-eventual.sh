# shellcheck shell=bash
fake_eventual() {
    local counter="$1" mode="$2" delay="$3" pending="$4" ready="$5" count=0
    case "$mode" in after | flapping | never) ;; *) return 2 ;; esac
    [[ "$delay" =~ ^(0|[1-9][0-9]*)$ ]] || return 2
    if [ -f "$counter" ]; then
        IFS= read -r count <"$counter" || return 2
    fi
    [[ "$count" =~ ^(0|[1-9][0-9]*)$ ]] || return 2
    count=$((count + 1))
    printf '%s\n' "$count" >"$counter" || return 2
    if { [ "$mode" = after ] && [ "$count" -gt "$delay" ]; } ||
        { [ "$mode" = flapping ] && [ "$((count % 2))" -eq 0 ]; }; then
        printf '%s\n' "$ready"
    else
        printf '%s\n' "$pending"
    fi
}
