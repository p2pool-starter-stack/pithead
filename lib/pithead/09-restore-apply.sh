# Setup accepts the appliance backup layout, never arbitrary host paths from an archive.
# Trailing slashes name data trees; other entries name individual files. Keep the same list
# for membership checks and application so a newly accepted item cannot escape the mapping.
restore_setup_config_path() {
    case "$CONFIG_FILE" in
    /*) printf '%s\n' "$CONFIG_FILE" ;;
    *) printf '%s\n' "$PWD/$CONFIG_FILE" ;;
    esac
}

# The accepted layout, named relative to whatever directory the archive was made from — a
# genuine older release's `pithead backup` ran from the operator's own working directory, never
# this appliance's $PWD (#2181). restore_setup_root() finds that directory from the archive
# itself; restore_setup_members() and restore_apply() match/extract relative to it, never
# assuming it is $PWD. restore_setup_config_path() maps the one path-shaped exception
# ($CONFIG_FILE) to its destination on THIS box; every other item joins directly onto $PWD.
restore_setup_relative_items() {
    printf '%s\n' "$CONFIG_FILE" "$ENV_FILE" "Caddyfile" \
        "data/tor/" "data/dashboard/" "data/monero/" \
        "data/tari/" "data/p2pool/"
}

# The single absolute directory every member of a genuine backup shares — found from wherever
# `config.json` sits, since that item is always present and never a directory. Requires exactly
# one match: a backup with config.json at two different depths is not one this codebase ever
# produces, so more than one is corruption or an attack, not a layout to guess between. An
# already-absolute $CONFIG_FILE (only a single-invocation validation override, never the wizard
# restore path) has no archive-relative root to detect.
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

# The whole restore acceptance, shared by its doors — the wizard's spool channel
# (firstboot_consume_restore), the installer applying an accepted restore onto the target's data
# (install_restore_to_target) and a legacy ESP pre-seed (consume_preseed_restore): size cap,
# encryption detection, decrypt verification, tar integrity, path-safety audit, extract-and-validate
# through a staging copy, then commit. One set of checks, several doors.
# With <config-only-dest> set, the validated config is copied there and NOTHING ELSE touches
# this machine — the installer's accept step, where the restored tree belongs to the TARGET and
# decrypted keys must never rest on the stick. <destination-root> applies the full restore under
# a mounted target instead of this process's working directory. rc 0: done. rc 1: refused, one
# page-ready line in <errfile>. Never deletes <archive> — the callers own their files.
restore_apply() ( # <archive> <passphrase> <errfile> [<config-only-dest>] [<destination-root>] [<staging-root>]
    local archive="$1" pass="$2" errf="$3" cfg_dest="${4:-}" dest_root="${5:-$PWD}" stage_root="${6:-$(restore_stage_root)}"
    local size magic encrypted=0 tmp plain tree staged_cfg err root restore_rc=0

    # Server-side cap already refused an oversize upload before it reached the spool; checked
    # again here so a file dropped by any other means gets the same honest refusal.
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
    # #1239 (live KVM guest evidence): the archive's .env is the SOURCE machine's own —
    # DEPLOYMENT_COMPLETED=true there records THAT machine's prior deployment, not this
    # hardware's. Every door that reaches here feeds a headless `setup()` on the restored machine
    # (firstboot's spool-accept path, or the installed target's first boot after the installer
    # applied the restore): setup()'s
    # is_deployed guard exists to stop an operator re-running setup on a box that is already
    # live (#924), and it has no way to tell "restored, never provisioned HERE" apart from
    # "live" — a carried true fires that guard's exact fatal, no-tty refusal, and setup never
    # runs: prepare_directories, render_env, provision_tor never fire, no container starts. A
    # just-restored box has NOT completed deployment on this hardware — clear the marker in the
    # staged .env, before the commit, so the caller's setup() actually provisions it and a
    # failure here leaves the live side untouched (#2689). The staged canonicalizer has already
    # retained only validated generated secrets and Tor identity while deriving host and policy
    # from config; this path changes its one hardware-specific lifecycle value. Scoped to THIS
    # commit path on purpose — stack_restore (the admin `./pithead restore` command, for a box already
    # deployed on its own hardware) has its own separate extraction and never calls restore_apply,
    # so a live box's restore keeps its completion marker exactly as it should.
    if ! safe_sed 's/^DEPLOYMENT_COMPLETED=.*/DEPLOYMENT_COMPLETED=false/' "$tree/$root$ENV_FILE"; then
        printf 'could not apply the backup files' >"$errf"
        return 1
    fi
    # The dashboard database carries the source machine's #35 sync-gate release (#2626); this
    # machine's chains may not be synced. Planting the marker in the STAGED tree, beside the
    # DEPLOYMENT_COMPLETED clear above, makes it land atomically with the rest of the commit — it
    # either arrives with a genuine dashboard database or not at all, with no separate failure
    # mode and no extra rollback bookkeeping in restore_commit_items.
    if [ -d "$tree/${root}data/dashboard" ] && ! : >"$tree/${root}data/dashboard/sync-gate-reset"; then
        printf 'could not apply the backup files' >"$errf"
        return 1
    fi
    # Apply only the accepted files/data trees, from wherever the archive's own root staged them
    # to their fixed destination under <destination-root> (this box's $PWD, or the installer's
    # mounted target), all or nothing (restore_commit_items). Do not copy staging's ancestor
    # directories onto /: their metadata is not part of the backup contract.
    local rc=0
    restore_commit_items "$tree/$root" "$tmp" "$dest_root" || rc=$?
    case "$rc" in
    0) ;;
    2)
        printf 'could not apply the backup files, and some previous files could not be put back — they are kept beside their original names as .restore-old copies' >"$errf"
        return 1
        ;;
    3)
        printf 'could not apply the backup files; the previous files are back, but some files the restore added could not be removed — look for .restore copies and new chain files' >"$errf"
        return 1
        ;;
    *)
        printf 'could not apply the backup files — nothing on this machine was changed' >"$errf"
        return 1
        ;;
    esac
    return 0
)

# Consume a restore-at-setup submission (#909, #786 sub-issue B): an uploaded encrypted backup
# archive + its emergency-kit passphrase, in place of the config form. Same decrypt/verify
# machinery as `stack_restore` (magic-byte format check, full-stream integrity verify BEFORE
# anything is touched), but staged through a COPY like consume_preseed_config — the exact
# validate-through-a-copy idiom this codebase already uses for "never mutate real state until
# accepted" — because a wizard-time restore must be able to fail clean and fall back to the
# form, not leave a half-restored Tor identity or dashboard database behind for a follow-up
# manual submit to inherit. rc: 0 landed (the config candidate + $spool/applied, identical to a
# typed submission — the caller falls into the SAME accept path), 1 rejected (error.txt
# written), 2 none, 3 its temporary secrets could not be cleared safely. The passphrase lives
# only in the volatile submission spool, is read once and deleted either way — it never outlives
# this call, except that an installer's accepted pair parks in the volatile carry dir until the
# installer applies it to the target without crossing the ESP.
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
    # Error text is private too: restore_apply never receives a page-writable path.
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
