_caddyfile_format() {
    local tmp
    tmp=$(mktemp "$1.XXXXXX") || return 1
    awk '
        { sub(/[ \t]+$/, "") }
        $0 == "" { if (out) blank = 1; next }
        {
            body = $0
            sub(/^ +/, "", body)
            if (body ~ /^}/) blank = 0
            if (blank && !opened) print ""
            blank = 0
            if (body ~ /^}/ && depth > 0) depth--
            indent = ""
            for (i = 0; i < depth; i++) indent = indent "\t"
            print indent body
            out = 1
            opened = (body ~ /{$/)
            if (opened) depth++
        }
    ' "$1" >"$tmp" && cat "$tmp" >"$1"
    rm -f "$tmp"
}
