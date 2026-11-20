# Quote one operator-supplied systemd Exec= argument; backslash, quote, dollar and percent are
# unit-file syntax, and the caller needs one argument after systemd expands the line.
quadlet_quote_exec_arg() {
    local v="${1//\\/\\\\}"
    v=${v//\"/\\\"}
    v=${v//%/%%}
    v=${v//\$/\$\$}
    printf '"%s"' "$v"
}

quadlet_refuse_control_chars() {
    local envf="$1" key val
    [ -f "$envf" ] || error "render-quadlet: env file not found: $envf"
    while IFS= read -r key; do
        val=$(
            env_get_file "$envf" "$key"
            printf x
        ) || error "render-quadlet: $key in $envf holds a CR or LF. Refusing to render; no output was created."
        case "$val" in
        *$'\r'* | *$'\n'*) error "render-quadlet: $key in $envf holds a CR or LF, which would forge unit-file lines. Refusing to render; no output was created." ;;
        esac
    done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$envf" | sort -u)
}
