# Consume a restore upload (#909, #786 B), verifying and validating a copy before mutation.
# rc: 0 landed like typed config, 1 rejected with error.txt, 2 none, 3 cleanup unsafe. Submitted
# and accepted passphrases live only in volatile storage; the installer applies one without crossing the ESP.
restore_carry_dir() { printf '%s' "${PITHEAD_RESTORE_CARRY_DIR:-/run/pithead-restore}"; }
restore_submission_dir() { printf '%s' "${PITHEAD_RESTORE_SUBMISSION_DIR:-/run/pithead-restore-submit}"; }
restore_stage_root() { printf '%s' "${PITHEAD_RESTORE_STAGE_ROOT:-/run/pithead-restore-stage}"; }
clear_restore_carry() { # [<carry-dir>]
    rm -rf -- "${1:-$(restore_carry_dir)}" || {
        warn "Could not clear the temporary restore handoff — reboot before trying another install."
        return 1
    }
}
clear_restore_stage() { # <volatile-stage-dir>
    rm -rf -- "$1" || {
        warn "Could not clear the private restore staging area — reboot before continuing."
        return 1
    }
}
clear_setup_candidate() { # <secret-file>...
    rm -f -- "$@" || {
        warn "Could not clear temporary setup credentials — do not leave the machine unattended."
        return 1
    }
}
clear_legacy_restore_carry() { # [<ESP-dir>]
    local dir="${1:-$PRESEED_DIR}"
    rm -f -- "$dir/pithead-restore.enc" "$dir/pithead-restore-pass" "$dir/pithead-setup-wizard" || {
        warn "Could not clear every legacy restore handoff file — do not leave the machine unattended."
        return 1
    }
}
clear_restore_submission() { # <archive-spool> [<passphrase-spool>] [<keep-archive|keep-marker>]
    local pass_dir="${2:-$1}" mode="${3:-}" paths
    case "$mode" in
    keep-archive) paths=("$1/restore-passphrase" "$pass_dir/restore-passphrase") ;;
    keep-marker) paths=("$1/restore-archive" "$pass_dir/restore-archive" "$1/restore-passphrase" "$pass_dir/restore-passphrase") ;;
    *) paths=("$1/restore-archive" "$pass_dir/restore-archive" "$1/restore-passphrase" "$pass_dir/restore-passphrase" "$1/restore-inflight") ;;
    esac
    rm -f -- "${paths[@]}" || {
        warn "Could not clear the submitted restore files — do not leave the machine unattended."
        wizard_spool_publish "$1" error.txt printf '%s' 'Could not clear the submitted restore files safely.' || true
        return 1
    }
}
clear_restore_snapshots() { # <private-dir>...
    local dir rc=0
    for dir in "$@"; do
        [ -z "$dir" ] || wizard_spool_clean_checked "$dir" || rc=1
    done
    [ "$rc" = 0 ] || {
        warn "Could not clear every private restore snapshot — do not leave the machine unattended."
        return 1
    }
}
# Keep one appliance-layout list for membership checks and application; slashes name trees.
restore_setup_config_path() {
    case "$CONFIG_FILE" in
    /*) printf '%s\n' "$CONFIG_FILE" ;;
    *) printf '%s\n' "$PWD/$CONFIG_FILE" ;;
    esac
}
# Find the archive's own working directory instead of assuming this appliance's $PWD (#2181).
# The config maps through restore_setup_config_path; every other accepted item joins onto $PWD.
restore_setup_relative_items() {
    printf '%s\n' "$CONFIG_FILE" "$ENV_FILE" "Caddyfile" \
        "data/tor/" "data/dashboard/" "data/monero/" \
        "data/tari/" "data/p2pool/"
}
# Find the archive's single shared root from config.json; ambiguity or an absolute override fails.
restore_setup_root() { # <tar name listing>
    case "$CONFIG_FILE" in /*) return 1 ;; esac
    local member root="" hits=0
    while IFS= read -r member; do
        case "$member" in
        "$CONFIG_FILE")
            root=""
            hits=$((hits + 1))
            ;;
        */"$CONFIG_FILE")
            root="${member%"$CONFIG_FILE"}"
            hits=$((hits + 1))
            ;;
        esac
    done <<<"$1"
    [ "$hits" -eq 1 ] || return 1
    printf '%s' "$root"
}
restore_setup_archive_within_limits() { # <names-file> <verbose-file> [max-members] [max-bytes]
    local members bytes
    members=$(wc -l <"$1")
    [ "$members" -le "${3:-4096}" ] && [ "$(wc -c <"$1")" -le 1048576 ] || return 1
    bytes=$(awk '$1 ~ /^-/ { if ($3 !~ /^[0-9]+$/) exit 1; total += $3 } END { printf "%.0f", total }' "$2") || return 1
    [ "$bytes" -le "${4:-1073741824}" ]
}
restore_setup_tar_list() { # <archive> <tar-list-option> <output> [max-KiB] [seconds]
    timeout "${5:-30}" bash -c \
        'ulimit -f "$1"; exec tar --numeric-owner --quoting-style=escape "$2" "$3"' \
        _ "${4:-4096}" "$2" "$1" >"$3" 2>/dev/null
}

restore_setup_publish_file() { # <source> <destination>
    local publish
    publish=$(mktemp "${2}.restore.XXXXXXXXXX") || return 1
    if ! install -m 600 "$1" "$publish" || ! mv -fT -- "$publish" "$2"; then
        clear_setup_candidate "$publish" || true
        return 1
    fi
}

restore_setup_members() { # <tar name listing> <root, from restore_setup_root>
    local member item accepted directory root="$2"
    while IFS= read -r member; do
        case "$member" in '' | /* | *\\* | . | ./* | */./* | */. | *//* | ../* | */../* | */..) return 1 ;; esac
        directory=0
        [[ "$member" = */ ]] && directory=1
        member="${member%/}"
        case "$member" in
        "$root"*) member="${member#"$root"}" ;;
        *) return 1 ;; # a member outside the archive's own single root is a mixed or forged layout
        esac
        accepted=0
        while IFS= read -r item; do
            if [[ "$item" = */ ]]; then
                [[ "$member" = "$item"* ]] && accepted=1
                [[ "$member" = "${item%/}" && "$directory" = 1 ]] && accepted=1
            elif [ "$member" = "$item" ] && [ "$directory" = 0 ]; then
                accepted=1
            fi
        done < <(restore_setup_relative_items)
        [ "$accepted" = 1 ] || return 1
    done <<<"$1"
}

# Shared acceptance for wizard uploads and legacy ESP pre-seeds: cap, decrypt, inspect, stage,
# validate, then commit.
# With <config-only-dest> set, only the validated config is copied there. <destination-root>
# applies the full restore under a mounted target instead of this process's working directory.
# rc 0: done. rc 1: refused, one page-ready line in <errfile>. Never deletes <archive>.
restore_apply() ( # <archive> <passphrase> <errfile> [<config-only-dest>] [<destination-root>] [<staging-root>]
    local archive="$1" pass="$2" errf="$3" cfg_dest="${4:-}" dest_root="${5:-$PWD}" stage_root="${6:-$(restore_stage_root)}"
    local size magic encrypted=0 tmp plain tree staged_cfg err root restore_rc=0

    # Repeat the server cap for archives supplied by another path.
    size=$(wc -c <"$archive" 2>/dev/null || echo 0)
    if [ "$size" -gt "$RESTORE_MAX_BYTES" ]; then
        printf 'backup archive is too large (max %s MB) — a Pithead backup holds only config, keys and the dashboard database, never the blockchains' "$((RESTORE_MAX_BYTES / 1048576))" >"$errf"
        return 1
    fi

    magic=$(head -c 8 "$archive" | od -An -tx1 | tr -d ' \n')
    case "$magic" in
    53616c7465645f5f) encrypted=1 ;; # "Salted__"
    1f8b*) ;;                        # gzip
    *)
        printf 'not a Pithead backup archive' >"$errf"
        return 1
        ;;
    esac

    prepare_restore_stage_root "$stage_root" || {
        printf 'could not prepare private restore staging' >"$errf"
        return 1
    }
    tmp=$(mktemp -d "$stage_root/.restore.XXXXXXXXXX") || {
        printf 'could not stage the restore' >"$errf"
        return 1
    }
    trap 'restore_rc=$?; if ! clear_restore_stage "$tmp"; then printf "%s" "could not clear private restore staging safely" >"$errf"; [ "$restore_rc" != 0 ] || restore_rc=3; fi; exit "$restore_rc"' EXIT
    plain="$archive"
    if [ "$encrypted" -eq 1 ]; then
        if [ -z "$pass" ]; then
            printf 'this archive is encrypted — enter its passphrase' >"$errf"
            return 1
        fi
        plain="$tmp/archive.tar.gz"
        umask 077
        if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass fd:3 -in "$archive" -out "$plain" 2>/dev/null 3< <(printf '%s' "$pass"); then
            printf 'wrong passphrase or corrupt archive' >"$errf"
            return 1
        fi
        local plain_magic
        plain_magic=$(head -c 2 "$plain" | od -An -tx1 | tr -d ' \n')
        if [ "$plain_magic" != "1f8b" ]; then
            printf 'wrong passphrase or corrupt archive' >"$errf"
            return 1
        fi
    fi

    # Path-safety audit BEFORE staging: the accepted tree is copied to "/" below, so a member with
    # an absolute path, a ".." component, or a symlink/hardlink could write outside the restore
    # set (a symlink extracted first, then written through). Modern tar refuses these, but the
    # destination is the filesystem root — do not trust the tar version. A Pithead backup carries
    # only regular files and dirs under known prefixes, so any escaping path or link is corruption
    # or an attack: fail closed. Lists names (whole-line, absolute/".." check) and the verbose
    # form (link check) separately, because a name with spaces is unparseable from `tar -tv`.
    if ! LC_ALL=C restore_setup_tar_list "$plain" -tzf "$tmp/names" ||
        ! LC_ALL=C restore_setup_tar_list "$plain" -tvzf "$tmp/verbose"; then
        printf 'archive fails integrity verification (tampered or truncated)' >"$errf"
        return 1
    fi
    if ! restore_setup_archive_within_limits "$tmp/names" "$tmp/verbose"; then
        printf 'archive expands beyond the setup restore limit — use the administrative restore workflow' >"$errf"
        return 1
    fi
    local rnames
    rnames=$(cat "$tmp/names")
    if printf '%s\n' "$rnames" | grep -E '^/|(^|/)\.\.(/|$)' >/dev/null ||
        grep -vE '^[-d]' "$tmp/verbose" >/dev/null; then
        printf 'archive contains unsafe paths or links — refusing to restore' >"$errf"
        return 1
    fi

    # An older supported release's `pithead backup` ran from the operator's own working
    # directory, not this appliance's $PWD (#2181) — so members are matched against the
    # archive's OWN single root, found from where config.json sits, not against $PWD.
    root=$(restore_setup_root "$rnames") || {
        printf 'archive contains files outside the appliance backup layout — refusing to restore' >"$errf"
        return 1
    }
    if ! restore_setup_members "$rnames" "$root"; then
        printf 'archive contains files outside the appliance backup layout — refusing to restore' >"$errf"
        return 1
    fi

    tree="$tmp/tree"
    mkdir -m 700 "$tree"
    (umask 077 && tar --no-same-owner --no-same-permissions -xzf "$plain" -C "$tree") || {
        printf 'could not stage the restore' >"$errf"
        return 1
    }
    if ! find "$tree" -type d -exec chmod 700 {} + ||
        ! find "$tree" -type f -exec chmod 600 {} + ||
        { [ "$(id -u)" = 0 ] && ! chown -R 0:0 "$tree"; }; then
        printf 'could not secure the staged restore' >"$errf"
        return 1
    fi

    # The archive stores paths relative to "/" (same convention `stack_backup`/`stack_restore`
    # use), so the staged config lands at exactly "$root$CONFIG_FILE" underneath $tmp/tree —
    # $root is the archive's own working directory, which need not be this box's $PWD.
    staged_cfg="$tree/$root$CONFIG_FILE"
    if [ ! -f "$staged_cfg" ] || ! jq -e . "$staged_cfg" >/dev/null 2>&1; then
        printf 'archive does not contain a usable configuration' >"$errf"
        return 1
    fi
    # Validated through the COPY — parse_and_validate_config fills in generated fields as it
    # goes (consume_preseed_config's own reasoning), and only a config that survives this is
    # ever promoted to the real config.json.
    if ! err=$(PITHEAD_CONFIG_FILE="$staged_cfg" PITHEAD_CONFIG_SET=1 bash -c "source '${BASH_SOURCE[0]}' && parse_and_validate_config" 2>&1); then
        printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240 >"$errf"
        return 1
    fi

    if [ -n "$cfg_dest" ]; then
        # Installer door: the credentials card needs the config while the full tree stays in the
        # volatile encrypted archive until the installer applies it to target data.
        restore_setup_publish_file "$staged_cfg" "$cfg_dest" || {
            printf 'could not apply the backup files' >"$errf"
            return 1
        }
        return 0
    fi
    if ! restore_canonicalize_derived "$staged_cfg" "$tree/$root$ENV_FILE" "$tree/${root}Caddyfile"; then
        printf 'archive contains invalid generated identity or secret state' >"$errf"
        return 1
    fi
    # Apply only the accepted files/data trees, from wherever the archive's own root staged them
    # to their fixed destination on THIS box ($PWD). Do not copy staging's ancestor directories
    # onto /: their metadata is not part of the backup contract.
    local rel source dest copy_failed=0
    while IFS= read -r rel; do
        source="$tree/$root$rel"
        [ -e "$source" ] || continue
        case "$rel" in
        "$CONFIG_FILE")
            if [ "$dest_root" = "$PWD" ]; then dest=$(restore_setup_config_path); else dest="$dest_root/$CONFIG_FILE"; fi
            ;;
        *) dest="$dest_root/$rel" ;;
        esac
        if [[ "$dest" = */ ]]; then
            dest="${dest%/}"
            case "$rel" in
            data/monero/ | data/tari/ | data/p2pool/)
                # Chain data survives this box's own `keep` policy (#2195): a restore must not
                # force a resync, so the archive's tree is MERGED into whatever already sits here
                # instead of replacing it — an existing file wins on a name collision, and files
                # only the archive has are added alongside it. See docs/operations.md's
                # "Restore collision rules" for why this differs from `pithead restore`.
                mkdir -p -- "$dest" || {
                    copy_failed=1
                    break
                }
                cp -a -n -- "$source"/. "$dest"/ || {
                    copy_failed=1
                    break
                }
                ;;
            *)
                rm -rf -- "$dest"
                # The parent may not exist yet (#2051): prepare_directories runs inside setup(),
                # which the restore doors call AFTER this, so on a fresh machine `data/` is simply
                # absent and `mv -T` fails ENOENT on the first tree item. That aborted the whole
                # apply with config.json and .env already written — a partial restore the caller
                # then read as a valid pre-seed, with the carried DEPLOYMENT_COMPLETED never
                # cleared because the clear sits past the failure. Measured on the bench: the
                # machine refused setup as already provisioned and ran zero containers.
                mkdir -p -- "$(dirname -- "$dest")" || {
                    copy_failed=1
                    break
                }
                mv -T -- "$source" "$dest" || {
                    copy_failed=1
                    break
                }
                ;;
            esac
        else
            restore_setup_publish_file "$source" "$dest" || {
                copy_failed=1
                break
            }
        fi
    done < <(restore_setup_relative_items)
    if [ "$copy_failed" = 1 ]; then
        printf 'could not apply the backup files' >"$errf"
        return 1
    fi
    # This archive records its source as deployed, but the wizard/pre-seed target is new hardware
    # and must run setup. Administrative `pithead restore` does not call this path (#1239).
    if [ -f "$dest_root/$ENV_FILE" ]; then
        safe_sed 's/^DEPLOYMENT_COMPLETED=.*/DEPLOYMENT_COMPLETED=false/' "$dest_root/$ENV_FILE"
    fi
    return 0
)

firstboot_consume_restore() ( # <spool-dir> [<installer>] [<volatile-passphrase-spool>] [<config-dest>]
    local spool="$1" installer="${2:-0}" submission="${3:-$1}" config_dest="${4:-$PWD/config.json}"
    local archive archive_spool="$spool" pass_snap="" pass="" rc=0 errf accepted=0
    wizard_submission_ready "$spool" || return 2
    if [ -e "$submission/restore-archive" ] || [ -L "$submission/restore-archive" ]; then
        archive_spool="$submission"
    fi
    archive=$(wizard_spool_request "$archive_spool" restore-archive "$RESTORE_MAX_BYTES") || rc=$?
    if [ "$rc" != 0 ]; then
        [ "$rc" = 2 ] || clear_restore_submission "$spool" "$submission" || return 1
        return "$rc"
    fi
    errf="${archive%/*}/error"
    trap 'rc=$?; rm -f "$errf" || { warn "Could not clear a private restore error snapshot."; [ "$rc" != 0 ] || rc=1; }; if ! clear_restore_snapshots "${archive%/*}" "${pass_snap%/*}"; then [ "$rc" != 0 ] || rc=1; fi; if [ "$accepted" != 1 ] && ! clear_restore_submission "$spool" "$submission"; then [ "$rc" != 0 ] || rc=1; fi; exit "$rc"' EXIT
    { set +x; } 2>/dev/null
    pass_snap=$(wizard_spool_snapshot "$submission" restore-passphrase 4096) || rc=$?
    clear_restore_submission "$spool" "$submission" keep-archive || return 1
    if [ "$rc" = 0 ]; then
        pass=$(cat "$pass_snap")
    elif [ "$rc" != 2 ]; then
        wizard_spool_publish "$spool" error.txt printf '%s' 'Unsafe restore passphrase file — submit again.'
        return 1
    fi
    umask 077
    rc=0
    if [ "$installer" -eq 1 ]; then
        local carry
        carry=$(restore_carry_dir)
        restore_apply "$archive" "$pass" "$errf" "$config_dest" "" "$(restore_stage_root)" || rc=$?
        if [ "$rc" != 0 ]; then
            wizard_spool_publish "$spool" error.txt cat "$errf"
            return "$rc"
        fi
        (umask 077 && mkdir -p "$carry" &&
            mv -fT "$archive" "$carry/archive" &&
            printf '%s' "$pass" >"$carry/pass") || {
            wizard_spool_publish "$spool" error.txt printf '%s' 'could not stage the restore for the install'
            clear_setup_candidate "$config_dest" || true
            clear_restore_carry "$carry" || true
            return 1
        }
    else
        restore_apply "$archive" "$pass" "$errf" || rc=$?
        if [ "$rc" != 0 ]; then
            wizard_spool_publish "$spool" error.txt cat "$errf"
            return "$rc"
        fi
    fi
    if ! clear_restore_snapshots "${archive%/*}" "${pass_snap%/*}"; then
        wizard_spool_publish "$spool" error.txt printf '%s' 'Could not clear private restore files safely. Reboot before continuing.' || true
        return 3
    fi
    archive="" pass_snap=""
    if ! wizard_spool_publish "$spool" restore-inflight true ||
        ! clear_restore_submission "$spool" "$submission" keep-marker ||
        ! wizard_spool_publish "$spool" applied true; then
        if [ "$installer" -eq 1 ]; then
            clear_setup_candidate "$config_dest" || true
            clear_restore_carry "$carry" || true
        fi
        return 1
    fi
    accepted=1
)
