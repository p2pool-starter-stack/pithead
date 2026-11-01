_config_compose_project_binary() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    printf '%s' "$binary"
}

_compose_project_name_go() {
    local binary project warning verdict helper_rc extra file="${ENV_FILE:-.env}" mode=missing
    local override_present=0 producer_rc=0 locale_name locale_value
    local current_cat current_grep trusted_cat trusted_grep
    binary=$(_config_compose_project_binary) || return 125
    if builtin shopt -q nocasematch; then return 125; fi
    if [ -n "${LC_ALL:-}" ]; then
        case "$LC_ALL" in C | POSIX) ;; *) return 125 ;; esac
    else
        for locale_name in LC_COLLATE LC_CTYPE LANG; do
            locale_value=${!locale_name:-}
            case "$locale_value" in "" | C | POSIX) ;; *) return 125 ;; esac
        done
    fi
    if [ "${COMPOSE_PROJECT_NAME+x}" = x ]; then
        override_present=1
    elif [ -e "$file" ]; then
        [ -f "$file" ] || return 125
        case "$file" in -*) return 125 ;; esac
        [ "$(builtin type -t cat 2>/dev/null)" = file ] && [ "$(builtin type -t grep 2>/dev/null)" = file ] || return 125
        current_cat=$(builtin type -P cat 2>/dev/null) || return 125
        current_grep=$(builtin type -P grep 2>/dev/null) || return 125
        trusted_cat=$(
            builtin hash -r
            builtin command -p -v cat 2>/dev/null
        ) || return 125
        trusted_grep=$(
            builtin hash -r
            builtin command -p -v grep 2>/dev/null
        ) || return 125
        [ "$current_cat" = "$trusted_cat" ] && [ "$current_grep" = "$trusted_grep" ] || return 125
        mode="file"
    fi
    {
        IFS= read -r -d '' project && IFS= read -r -d '' warning && IFS= read -r -d '' verdict &&
            IFS= read -r -d '' helper_rc && [ "$helper_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local helper_rc=0
        if [ "$mode" = file ]; then
            {
                cat "$file" 2>/dev/null || producer_rc=$?
                printf '\0%d\0%s\0%s\0%d\0' "$override_present" "${COMPOSE_PROJECT_NAME:-}" "$mode" "$producer_rc"
            } | PITHEAD_GO_HELPER=config-compose-project "$binary" 2>/dev/null || helper_rc=$?
        else
            printf '\0%d\0%s\0%s\0%d\0' "$override_present" "${COMPOSE_PROJECT_NAME:-}" "$mode" 0 |
                PITHEAD_GO_HELPER=config-compose-project "$binary" 2>/dev/null || helper_rc=$?
        fi
        printf '%d\0' "$helper_rc"
    ) || return 125
    if [ "$verdict" = 0 ] && [ -z "$warning" ] && [[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        printf '%s' "$project"
    elif [ "$verdict" = 1 ] && [ -z "$project" ]; then
        case "$warning" in
        "Use one literal COMPOSE_PROJECT_NAME assignment in the environment file." | \
            "COMPOSE_PROJECT_NAME must be a literal lowercase Compose project name.")
            warn "$warning"
            return 1
            ;;
        *) return 125 ;;
        esac
    else
        return 125
    fi
}
