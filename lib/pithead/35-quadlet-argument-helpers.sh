# Quote one operator-supplied systemd Exec= argument; backslash, quote, dollar and percent are
# unit-file syntax, and the caller needs one argument after systemd expands the line.
quadlet_quote_exec_arg() {
    local v="${1//\\/\\\\}"
    v=${v//\"/\\\"}
    v=${v//%/%%}
    v=${v//\$/\$\$}
    printf '"%s"' "$v"
}
