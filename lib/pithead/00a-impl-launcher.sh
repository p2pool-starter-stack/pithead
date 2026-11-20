_PITHEAD_IMPL_TABLE='help bash -
status bash -
payout-keys bash -
config-document bash -
caddy-render bash -
env-render bash -
doctor bash -'
_PITHEAD_IMPL_VERB_MAP='help help
-h help
--help help
version help
-V help
--version help
status status
doctor doctor'
_PITHEAD_IMPL_SELECTION=""
_PITHEAD_IMPL_REFUSAL=""

_pithead_impl_table() {
    printf '%s\n' "$_PITHEAD_IMPL_TABLE"
}

_pithead_impl_verb_map() {
    printf '%s\n' "$_PITHEAD_IMPL_VERB_MAP"
}

_pithead_impl_known_piece() {
    local name rest
    while read -r name _rest; do
        [ -n "$name" ] || continue
        [ "$name" = "$1" ] && return 0
    done <<<"$_PITHEAD_IMPL_TABLE"
    return 1
}

_pithead_impl_piece_list() {
    local name _rest out=""
    while read -r name _rest; do
        [ -n "$name" ] || continue
        if [ -z "$out" ]; then out="$name"; else out="$out $name"; fi
    done <<<"$_PITHEAD_IMPL_TABLE"
    printf '%s' "$out"
}

_pithead_impl_piece_for() {
    local v p out=""
    while read -r v p; do
        [ -n "$v" ] || continue
        [ "$v" = "$1" ] && out="$p"
    done <<<"$_PITHEAD_IMPL_VERB_MAP"
    printf '%s' "$out"
}

_pithead_impl_mode_for_piece() {
    local piece="$1" selection="$2" name default _flip entry mode
    if [ -z "$selection" ]; then
        mode=bash
        while read -r name default _flip; do
            [ "$name" = "$piece" ] && mode="$default"
        done <<<"$_PITHEAD_IMPL_TABLE"
        printf '%s' "$mode"
        return 0
    fi
    mode=bash
    while [ -n "$selection" ]; do
        entry="${selection%%,*}"
        if [ "$entry" = "$selection" ]; then selection=""; else selection="${selection#*,}"; fi
        entry="${entry//[[:space:]]/}"
        [ -n "$entry" ] || continue
        if [ "$entry" = bash ]; then
            printf bash
            return 0
        fi
        [ "$entry" = "$piece" ] && mode=go
    done
    printf '%s' "$mode"
}

_pithead_impl_mode_for() {
    local piece
    piece=$(_pithead_impl_piece_for "$1")
    [ -n "$piece" ] || {
        printf bash
        return 0
    }
    _pithead_impl_mode_for_piece "$piece" "$2"
}

_pithead_impl_selected() {
    local selection=""
    if [ -n "${PITHEAD_IMPL:-}" ]; then
        selection="$PITHEAD_IMPL"
    else
        _pithead_impl_read_selection || return 1
        selection="$_PITHEAD_IMPL_SELECTION"
    fi
    [ "$(_pithead_impl_mode_for_piece "$1" "$selection")" = go ]
}

_pithead_impl_read_selection() {
    local impl_file line extra owner mode
    _PITHEAD_IMPL_SELECTION=""
    _PITHEAD_IMPL_REFUSAL=""
    if [ -n "${PITHEAD_IMPL:-}" ]; then
        _PITHEAD_IMPL_SELECTION="$PITHEAD_IMPL"
        return 0
    fi
    impl_file="${PITHEAD_IMPL_FILE:-/etc/pithead-impl}"
    [ -f "$impl_file" ] || return 0
    if [ -L "$impl_file" ]; then
        _PITHEAD_IMPL_REFUSAL="$impl_file is a symlink; it must be a regular file owned by root"
        return 1
    fi
    owner=$(stat -c '%u' -- "$impl_file" 2>/dev/null) || owner=""
    if [ "$owner" != 0 ] && [ ! -O "$impl_file" ]; then
        _PITHEAD_IMPL_REFUSAL="$impl_file is owned by uid ${owner:-unknown}; it must be owned by root or by the invoking user"
        return 1
    fi
    mode=$(stat -c '%a' -- "$impl_file" 2>/dev/null) || mode=""
    if [ -n "$mode" ] && [ $((8#$mode & 8#022)) -ne 0 ]; then
        _PITHEAD_IMPL_REFUSAL="$impl_file is writable by group or other; tighten it to 0644 or stricter"
        return 1
    fi
    extra=""
    {
        IFS= read -r line || true
        IFS= read -r extra || true
    } <"$impl_file"
    if [ -n "$extra" ]; then
        _PITHEAD_IMPL_REFUSAL="$impl_file must hold exactly one PITHEAD_IMPL=<selection> line"
        return 1
    fi
    case "$line" in
    PITHEAD_IMPL=*) _PITHEAD_IMPL_SELECTION="${line#PITHEAD_IMPL=}" ;;
    *)
        _PITHEAD_IMPL_REFUSAL="$impl_file must hold exactly one PITHEAD_IMPL=<selection> line, found: $line"
        return 1
        ;;
    esac
    return 0
}

_pithead_impl_launch() {
    local verb="${1:-}" selection="" entry piece="" mode=bash name default _flip v p go_binary
    if [ -n "${PITHEAD_IMPL:-}" ]; then
        selection="$PITHEAD_IMPL"
    else
        _pithead_impl_read_selection ||
            error "Refusing the implementation selection: $_PITHEAD_IMPL_REFUSAL."
        selection="$_PITHEAD_IMPL_SELECTION"
    fi
    _PITHEAD_IMPL_SELECTION="$selection"
    while read -r v p; do
        [ -n "$v" ] || continue
        [ "$v" = "$verb" ] && piece="$p"
    done <<<"$_PITHEAD_IMPL_VERB_MAP"
    if [ -n "$selection" ]; then
        while [ -n "$selection" ]; do
            entry="${selection%%,*}"
            if [ "$entry" = "$selection" ]; then selection=""; else selection="${selection#*,}"; fi
            entry="${entry//[[:space:]]/}"
            [ -n "$entry" ] || continue
            if [ "$entry" = bash ]; then
                mode=bash
                selection=""
                break
            fi
            _pithead_impl_known_piece "$entry" ||
                error "PITHEAD_IMPL: unknown piece '$entry'. Known pieces: $(_pithead_impl_piece_list). Use PITHEAD_IMPL=bash to force the Bash reference implementation."
            if [ -n "$piece" ] && [ "$entry" = "$piece" ]; then mode=go; fi
        done
    elif [ -n "$piece" ]; then
        while read -r name default _flip; do
            [ "$name" = "$piece" ] && mode="$default"
        done <<<"$_PITHEAD_IMPL_TABLE"
    fi
    [ "$mode" = go ] || return 0
    go_binary="${PITHEAD_GO_BINARY:-$SCRIPT_DIR/go/bin/pithead}"
    if [ ! -x "$go_binary" ]; then
        return 0
    fi
    export PITHEAD_GO_REFERENCE="$PITHEAD_SELF"
    exec "$go_binary" "$@"
}

if [ "$_STACK_SOURCED" = "0" ]; then
    _pithead_impl_launch "$@"
fi
