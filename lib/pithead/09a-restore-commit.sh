# restore_apply's commit (#2689): publish every accepted item, or put back what was there. The
# commit used to write items one at a time straight over the live ones, so a failure on
# data/dashboard/ left the archive's config.json and .env beside this box's own Tor keys and
# database, reported as a failed restore with nothing to undo it. Now it runs in two passes:
#   1. stage: each replaced item is copied or moved beside its destination as
#      "<dest>.restore.XXXXXXXXXX", on the same filesystem, so that the swap is a rename. Nothing
#      live changes except a missing parent directory, which is created and removed again on
#      rollback if still empty.
#   2. swap: in restore_setup_relative_items order, the live item (a file, a tree or a planted
#      link, never followed) is renamed aside to "<dest>.restore-old.XXXXXXXXXX" and the staged
#      one renamed into place. The merged chain trees record which names the archive adds before
#      `cp -a -n` runs, since the files already there stay and only the added ones are undone.
# Any failure undoes the swaps already made, newest first, and removes what is still staged. The
# old copies are deleted only once every item is in place. rc 0: committed. rc 1: rolled back.
# rc 2: rolled back only in part; the previous copies that could not be restored are still
# beside their destinations under the .restore-old name.
restore_setup_item_dest() { # <relative item>
    case "$1" in
    "$CONFIG_FILE") restore_setup_config_path ;;
    *) printf '%s\n' "$PWD/${1%/}" ;;
    esac
}

restore_commit_items() ( # <staged root> <scratch dir>
    local stage_root="$1" scratch="$2" rel source dest staged aside added name i=0 failed=0
    local -a staged_items=() staged_paths=() made_dirs=() done_kind=() done_dest=() done_aside=()
    restore_commit_rollback() {
        local j k path rc=1
        local -a names
        for ((j = ${#done_dest[@]} - 1; j >= 0; j--)); do
            if [ "${done_kind[j]}" = merge ]; then
                # Newest name first, so an added directory is emptied before it is removed.
                mapfile -d '' names <"${done_aside[j]}" || rc=2
                for ((k = ${#names[@]} - 1; k >= 0; k--)); do
                    rm -rf -- "${done_dest[j]:?}/${names[k]:?}" || rc=2
                done
                continue
            fi
            rm -rf -- "${done_dest[j]}" || rc=2
            [ -z "${done_aside[j]}" ] || mv -T -- "${done_aside[j]}" "${done_dest[j]}" || rc=2
        done
        for path in "${staged_paths[@]}"; do rm -rf -- "$path" || rc=2; done
        for ((j = ${#made_dirs[@]} - 1; j >= 0; j--)); do rmdir -- "${made_dirs[j]}" 2>/dev/null || true; done
        return "$rc"
    }
    restore_commit_mkdir() { # <dir>: create it and the missing parents, recording each for rollback
        [ -d "$1" ] && return 0
        restore_commit_mkdir "$(dirname -- "$1")" && mkdir -- "$1" && made_dirs+=("$1")
    }
    restore_commit_new_names() { # <source tree> <dest tree>: NUL-separated names only the source has
        local path
        (cd -- "$1" && find . -mindepth 1 -print0) | while IFS= read -r -d '' path; do
            [ -e "$2/$path" ] || [ -L "$2/$path" ] || printf '%s\0' "$path"
        done
    }

    while IFS= read -r rel; do
        source="$stage_root/$rel"
        [ -e "$source" ] || continue
        dest=$(restore_setup_item_dest "$rel")
        case "$rel" in
        data/monero/ | data/tari/ | data/p2pool/) staged="" ;;
        */)
            # The parent may not exist yet (#2051): prepare_directories runs inside setup(), which
            # the restore doors call AFTER this, so on a fresh machine `data/` is simply absent.
            restore_commit_mkdir "$(dirname -- "$dest")" &&
                staged=$(mktemp -d "$dest.restore.XXXXXXXXXX") &&
                staged_paths+=("$staged") && mv -T -- "$source" "$staged" || failed=1
            ;;
        *)
            staged=$(mktemp "$dest.restore.XXXXXXXXXX") && staged_paths+=("$staged") &&
                install -m 600 "$source" "$staged" || failed=1
            ;;
        esac
        [ "$failed" = 0 ] || break
        staged_items+=("$rel"$'\t'"$staged")
    done < <(restore_setup_relative_items)

    for name in "${staged_items[@]}"; do
        [ "$failed" = 0 ] || break
        rel="${name%%$'\t'*}" staged="${name#*$'\t'}"
        dest=$(restore_setup_item_dest "$rel")
        if [ -z "$staged" ]; then
            # Chain data survives this box's own `keep` policy (#2195): a restore must not force a
            # resync, so the archive's tree is MERGED into whatever already sits here instead of
            # replacing it. An existing file wins on a name collision, and files only the archive
            # has are added alongside it. See docs/operations.md's "Restore collision rules" for
            # why this differs from `pithead restore`.
            source="$stage_root/$rel"
            added="$scratch/added.$i"
            i=$((i + 1))
            restore_commit_mkdir "$dest" && restore_commit_new_names "$source" "$dest" >"$added" &&
                done_kind+=(merge) && done_dest+=("$dest") && done_aside+=("$added") &&
                cp -a -n -- "$source"/. "$dest"/ || failed=1
            continue
        fi
        aside=""
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            aside=$(mktemp -u "$dest.restore-old.XXXXXXXXXX") && mv -T -- "$dest" "$aside" || {
                failed=1
                break
            }
        fi
        done_kind+=(replace) done_dest+=("$dest") done_aside+=("$aside")
        mv -fT -- "$staged" "$dest" || failed=1
    done

    if [ "$failed" = 1 ]; then
        restore_commit_rollback
        return
    fi
    for ((i = 0; i < ${#done_dest[@]}; i++)); do
        [ "${done_kind[i]}" = merge ] || [ -z "${done_aside[i]}" ] || rm -rf -- "${done_aside[i]}"
    done
    return 0
)
