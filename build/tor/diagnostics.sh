#!/bin/sh
set -u
data="${TOR_DATA_DIR:-/var/lib/tor}"
reply=
cookie=$(xxd -p -c 256 "${TOR_COOKIE_FILE:-$data/control_auth_cookie}" 2>/dev/null | tr -d '\n')
case "$cookie" in
"" | *[!0-9a-fA-F]*) ;;
*)
    reply=$(printf 'AUTHENTICATE %s\r\nGETINFO version\r\nGETINFO status/bootstrap-phase\r\nGETINFO circuit-status\r\nGETINFO entry-guards\r\nGETINFO consensus/valid-after\r\nGETINFO consensus/valid-until\r\nGETINFO status/circuit-established\r\nGETINFO status/enough-dir-info\r\nQUIT\r\n' "$cookie" |
        timeout 5 nc -w 3 127.0.0.1 9051 2>/dev/null | head -c 1048576) || reply=
    ;;
esac
out=$(printf '%s\n' "$reply" | tr -d '\r' | awk '
    function emit(l) { buf[++nb] = l }
    function tok(v, re) { return v ~ re ? v : "other" }
    function stamp(v) { return v ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ }
    function circuit(line,    n, f, i, purpose) {
        n = split(line, f, " ")
        if (n < 2) return
        purpose = "UNKNOWN"
        for (i = 3; i <= n; i++) if (f[i] ~ /^PURPOSE=/) purpose = substr(f[i], 9)
        emit("circuit=" tok(f[2], "^[A-Z_]+$") " " tok(purpose, "^[A-Z_]+$"))
    }
    function guard(line,    n, f) {
        n = split(line, f, " ")
        if (n >= 2) emit("guard=" tok(f[2], "^[a-z-]+$"))
    }
    NR == 1 { if ($0 != "250 OK") exit; ok = 1; next }
    mode != "" && $0 == "." { mode = ""; next }
    mode == "circuit" { circuit($0); next }
    mode == "guard" { guard($0); next }
    /^250 closing connection$/ { closed = 1; next }
    /^250\+circuit-status=/ { mode = "circuit"; next }
    /^250\+entry-guards=/ { mode = "guard"; next }
    /^250-circuit-status=./ { circuit(substr($0, 20)); next }
    /^250-entry-guards=./ { guard(substr($0, 18)); next }
    /^250-version=/ { split(substr($0, 13), ver, " "); emit("version=" tok(ver[1], "^[0-9][0-9a-z.-]*$")); next }
    /^250-status\/bootstrap-phase=/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^PROGRESS=[0-9]+$/) emit("bootstrap_progress=" substr($i, 10))
            if ($i ~ /^TAG=/) emit("bootstrap_tag=" tok(substr($i, 5), "^[a-z_]+$"))
        }
        next
    }
    /^250-status\/circuit-established=[01]$/ { emit("circuit_established=" substr($0, 32)); next }
    /^250-status\/enough-dir-info=[01]$/ { emit("enough_dir_info=" substr($0, 28)); next }
    /^250-consensus\/valid-after=/ { v = substr($0, 27); if (stamp(v)) { cons[++seen] = "consensus_valid_after=" v } next }
    /^250-consensus\/valid-until=/ { v = substr($0, 27); if (stamp(v)) { cons[++seen] = "consensus_valid_until=" v } next }
    END {
        if (!ok || !closed || mode != "") { print "control=unreachable"; exit }
        print "control=ok"
        for (i = 1; i <= nb; i++) print buf[i]
        if (seen == 2) print cons[1] "\n" cons[2] "\nconsensus_source=control"
    }
')
printf '%s\n' "$out"
case "$out" in
*consensus_source=control*) ;;
*)
    file="$data/cached-microdesc-consensus"
    [ -f "$file" ] || file="$data/cached-consensus"
    if [ -f "$file" ]; then
        echo "consensus_source=file"
        head -n 40 "$file" | awk '
            /^valid-after [0-9-]+ [0-9:]+$/ { print "consensus_valid_after=" $2 " " $3 }
            /^valid-until [0-9-]+ [0-9:]+$/ { print "consensus_valid_until=" $2 " " $3 }'
        mtime=$(stat -c %Y "$file" 2>/dev/null) && case "$mtime" in *[!0-9]* | "") ;; *) echo "consensus_file_mtime=$mtime" ;; esac
    fi
    ;;
esac
exit 0
