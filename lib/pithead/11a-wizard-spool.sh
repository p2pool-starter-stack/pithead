# The host/page filesystem boundary. The outer directory is root-owned and sticky so the
# page can submit requests but cannot replace host-owned entries. Private staging directories
# keep even a file destined for uid 1000 unreachable until its atomic publication.
prepare_wizard_spool() { # <spool-dir>
    [ ! -L "$1" ] || return 1
    mkdir -p "$1" || return 1
    if [ "$(id -u)" = 0 ]; then
        if ! chown 0:1000 "$1" || ! chmod 1770 "$1"; then
            chmod 700 "$1" 2>/dev/null || true
            return 1
        fi
    else
        [ "$(stat -c '%u' "$1")" = "$(id -u)" ] && chmod 700 "$1"
    fi
}

wizard_spool_private() { # <spool-dir> -> private directory
    prepare_wizard_spool "$1" || return 1
    (
        umask 077
        mktemp -d "$1/.host.XXXXXXXXXX"
    )
}

# Cleanup never recursively follows an untrusted submission (a directory is not an input).
wizard_spool_clean_checked() { # <private-dir>
    local rc=0
    rm -f -- "$1/input" "$1/value" || rc=1
    rmdir -- "$1/input" 2>/dev/null || true # an unsafe submitted directory, never recursive
    rmdir -- "$1" || rc=1
    return "$rc"
}
wizard_spool_clean() { # <private-dir> — ordinary callers deliberately keep best-effort cleanup
    wizard_spool_clean_checked "$1" >/dev/null 2>&1 || true
}

prepare_restore_stage_root() { # <volatile-root>
    [ ! -L "$1" ] || return 1
    (umask 077 && mkdir -p "$1") || return 1
    [ "$(stat -c '%u' "$1")" = "$(id -u)" ] && chmod 700 "$1"
}

clear_restore_stages() { # [<volatile-root>]
    local root="${1:-$(restore_stage_root)}" dir rc=0
    [ -e "$root" ] || [ -L "$root" ] || return 0
    prepare_restore_stage_root "$root" || rc=1
    if [ "$rc" = 0 ]; then
        for dir in "$root"/.restore.*; do
            { [ -e "$dir" ] || [ -L "$dir" ]; } || continue
            if [ -L "$dir" ] || [ ! -d "$dir" ] || [ "$(stat -c '%u' "$dir")" != "$(id -u)" ]; then
                rc=1
                continue
            fi
            clear_restore_stage "$dir" || rc=1
        done
    fi
    [ "$rc" = 0 ] || warn "Could not clear temporary restore staging safely — reboot before continuing."
    return "$rc"
}

# Older restore snapshots lived in the persistent spool. Only clean host-owned private dirs;
# a page-owned lookalike must never redirect cleanup outside the spool.
clear_legacy_wizard_snapshots() { # <spool-dir>
    local dir rc=0
    [ ! -L "$1" ] || return 1
    for dir in "$1"/.host.*; do
        { [ -e "$dir" ] || [ -L "$dir" ]; } || continue
        [ ! -L "$dir" ] && [ -d "$dir" ] && [ "$(stat -c '%u' "$dir")" = "$(id -u)" ] || continue
        wizard_spool_clean_checked "$dir" || rc=1
    done
    [ "$rc" = 0 ] || warn "Could not clear every legacy private wizard snapshot — do not leave the machine unattended."
    return "$rc"
}

wizard_spool_publish() ( # <spool-dir> <name> <producer> [args...]
    local spool="$1" name="$2" tmp
    shift 2
    case "$name" in '' | */* | . | ..) return 1 ;; esac
    tmp=$(wizard_spool_private "$spool") || return 1
    trap 'wizard_spool_clean "$tmp"' EXIT
    umask 077
    "$@" >"$tmp/value" || return 1
    if [ "$(id -u)" = 0 ]; then
        case "$name" in
        error.txt | last-attempt.json | installing | setup-failed)
            chmod 600 "$tmp/value" && chown 1000:1000 "$tmp/value" || return 1
            ;;
        *) chmod 640 "$tmp/value" && chown 0:1000 "$tmp/value" || return 1 ;;
        esac
    fi
    # -T replaces the entry itself, including a symlink to a directory. No pathname operation
    # after publication may chmod, chown, truncate or read back a page-owned destination.
    mv -fT -- "$tmp/value" "$spool/$name"
)

# Pin the directory entry with a non-dereferencing hard link inside our private directory.
# Inspect it there BEFORE opening (including FIFOs); the page cannot replace that name. Copy
# into a fresh inode before parsing: a page process may still hold the original inode open.
# All validation and subsequent use must use the returned snapshot, never the request again.
wizard_spool_snapshot() ( # <spool-dir> <name> [max-bytes] -> private snapshot path
    local spool="$1" name="$2" limit="${3:-1048576}" tmp owner size
    case "$name" in '' | */* | . | ..) return 1 ;; esac
    [ -e "$spool/$name" ] || [ -L "$spool/$name" ] || return 2
    tmp=$(wizard_spool_private "$spool") || return 1
    trap 'wizard_spool_clean_checked "$tmp" >/dev/null 2>&1 || warn "Could not clear a failed private wizard snapshot."' EXIT
    ln -P -- "$spool/$name" "$tmp/input" 2>/dev/null || return 1
    [ ! -L "$tmp/input" ] && [ -f "$tmp/input" ] || return 1
    [ "$(stat -c '%h' "$tmp/input")" = 2 ] || return 1
    owner=$(stat -c '%u' "$tmp/input")
    [ "$owner" = "$(id -u)" ] || [ "$owner" = 1000 ] || return 1
    size=$(stat -c '%s' "$tmp/input")
    [ "$size" -le "$limit" ] || return 3
    umask 077
    head -c "$((limit + 1))" -- "$tmp/input" >"$tmp/value" || return 1
    [ "$(stat -c '%s' "$tmp/value")" -le "$limit" ] || return 3
    rm -f -- "$tmp/input" || return 1
    trap - EXIT
    printf '%s\n' "$tmp/value"
)

wizard_spool_read() ( # <spool-dir> <name> -> bounded text snapshot
    local snap rc=0
    snap=$(wizard_spool_snapshot "$1" "$2") || return "$?"
    cat "$snap" || rc=$?
    wizard_spool_clean "${snap%/*}"
    return "$rc"
)

wizard_spool_has() { wizard_spool_read "$1" "$2" >/dev/null 2>&1; }

wizard_submission_ready() { # <spool-dir>
    ! wizard_spool_has "$1" submission-staging || wizard_spool_has "$1" submission-active
}

wizard_clear_submission_transaction() { # <spool-dir>
    if wizard_spool_has "$1" submission-staging &&
        ! wizard_spool_has "$1" submission-active; then
        rm -f -- "$1/config.json" || return 1
    fi
    rm -f -- "$1/submission-staging" "$1/submission-active" || {
        warn "Could not clear the active setup transaction — reboot before submitting again."
        return 1
    }
}

write_handoff_card() { wizard_spool_publish "$1" handoff.json cat; }

# Submission consumers report unsafe entries as a retryable failure. Text/marker readers use
# snapshot directly, so checking an absent marker does not manufacture a page error.
wizard_spool_request() { # <spool-dir> <name> [max-bytes] -> snapshot
    local snap rc=0
    snap=$(wizard_spool_snapshot "$@") || rc=$?
    if [ "$rc" = 0 ]; then
        printf '%s\n' "$snap"
    elif [ "$rc" = 1 ] || [ "$rc" = 3 ]; then
        rm -f -- "$1/$2" 2>/dev/null || true
        if [ "$rc" = 3 ]; then
            wizard_spool_publish "$1" error.txt printf '%s' 'Setup submission is too large — use a smaller file and submit again.'
        else
            wizard_spool_publish "$1" error.txt printf '%s' 'Unsafe setup submission — submit the settings again.'
        fi
        return 1
    else
        return "$rc"
    fi
}
