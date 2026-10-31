# shellcheck shell=bash
printf 'CLEARNET_STATE_DIR=%s/clearnet-state\nCONTROL_DIR=%s/control\n' "$WORK_DIR" "$WORK_DIR" >"$WORK_DIR/.env"
printf '{}\n' >"$WORK_DIR/config.json"
export PITHEAD_CONFIG_FILE="$WORK_DIR/config.json"
sudo() {
    [ "$1" = rm ] || return 125
    shift
    local arg
    for arg in "$@"; do
        case "$arg" in -f | "$WORK_DIR"/*) ;; *) return 125 ;; esac
    done
    command rm "$@"
}
