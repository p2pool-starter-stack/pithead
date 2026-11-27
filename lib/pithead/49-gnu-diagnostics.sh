GNU_FEATURES=()

coreutils_banner() {
    stat --version 2>/dev/null | head -n 1
}

detect_coreutils() { # sets GNU_FEATURES to the behaviors this host's coreutils lack
    GNU_FEATURES=()
    local d
    d=$(mktemp -d) || return 1
    printf 'x' >"$d/s" || {
        rm -rf -- "$d"
        return 1
    }

    stat -Lc '%u %s %a' -- "$d" 2>/dev/null | grep -Eq '^[0-9]+ [0-9]+ [0-9]+$' ||
        GNU_FEATURES+=('stat -c/-Lc')
    printf 'x' >"$d/s2" && ln -s "$d" "$d/dirlink" &&
        mv -fT -- "$d/s2" "$d/dirlink" 2>/dev/null && [ "$(cat "$d/dirlink")" = x ] ||
        GNU_FEATURES+=('mv -T')
    printf 'keep' >"$d/a" && printf 'lose' >"$d/b" && mv -n -- "$d/b" "$d/a" 2>/dev/null
    [ "$(cat "$d/a")" = keep ] && [ -f "$d/b" ] || GNU_FEATURES+=('mv -n')
    mkdir -p "$d/src/sub" && touch "$d/src/f" && ln -s f "$d/src/sub/l" &&
        cp -a -- "$d/src" "$d/dst" && [ -L "$d/dst/sub/l" ] && [ -f "$d/dst/f" ] ||
        GNU_FEATURES+=('cp -a')
    ln -s "$d/a" "$d/rd" && cp --remove-destination -- "$d/src/f" "$d/rd" 2>/dev/null &&
        [ ! -L "$d/rd" ] || GNU_FEATURES+=('cp --remove-destination')
    printf 'x' >"$d/p600" && chmod 600 "$d/p600" && cp -p -- "$d/p600" "$d/pnew" &&
        [ "$(stat -c '%a' "$d/pnew" 2>/dev/null)" = 600 ] || GNU_FEATURES+=('cp -p')
    ln -s f "$d/cnp" && cp -p --no-dereference "$d/cnp" "$d/cnp2" 2>/dev/null &&
        [ -L "$d/cnp2" ] || GNU_FEATURES+=('cp --no-dereference')
    printf 'x' >"$d/lp" && ln -s lp "$d/lpsl" && ln -P -- "$d/lpsl" "$d/lphl" 2>/dev/null &&
        [ -L "$d/lphl" ] || GNU_FEATURES+=('ln -P')
    [ "$(printf 'abcd' | head -c 2)" = ab ] || GNU_FEATURES+=('head -c')
    [ "$(printf 'v1.10\nv1.9\n' | sort -V | head -n 1)" = v1.9 ] || GNU_FEATURES+=('sort -V')
    [ "$(printf 'b\0a\0' | sort -z | tr '\0' ' ')" = 'a b ' ] || GNU_FEATURES+=('sort -z')
    du -sck -- "$d" 2>/dev/null | head -n 1 | grep -Eq '^[0-9]+[[:space:]]' ||
        GNU_FEATURES+=('du -sk')
    realpath -m -- "$d/nope/deeper" 2>/dev/null | grep -q '/nope/deeper$' ||
        GNU_FEATURES+=('realpath -m')
    realpath -ms -- "$d/s/../nope2" 2>/dev/null | grep -q '/nope2$' ||
        GNU_FEATURES+=('realpath -ms')
    realpath -e -- "$d/s" >/dev/null 2>&1 || GNU_FEATURES+=('realpath -e')
    readlink -f -- "$d/nope" 2>/dev/null | grep -q '/nope$' || GNU_FEATURES+=('readlink -f')
    rm -rf -- "$d"
    return 0
}
