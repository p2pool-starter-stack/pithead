# Consume a restore-at-setup submission (#909, #786 sub-issue B): an uploaded encrypted backup
# archive + its emergency-kit passphrase, in place of the config form. Same decrypt/verify
# machinery as `stack_restore` (magic-byte format check, full-stream integrity verify BEFORE
# anything is touched), but staged through a COPY like consume_preseed_config — the exact
# validate-through-a-copy idiom this codebase already uses for "never mutate real state until
# accepted" — because a wizard-time restore must be able to fail clean and fall back to the
# form, not leave a half-restored Tor identity or dashboard database behind for a follow-up
# manual submit to inherit. rc: 0 landed (config.json + $spool/applied, identical to a typed
# submission — the caller falls into the SAME accept path), 1 rejected (error.txt written), 2
# none. The passphrase is read once and deleted immediately either way — it never outlives
# this call.
# Where an installer boot parks an ACCEPTED restore for the carry to the target's ESP —
# root-only tmpfs, gone at power-off, never mounted into any container. Overridable so the
# shell suite can run this without root's /run.
restore_carry_dir() { printf '%s' "${PITHEAD_RESTORE_CARRY_DIR:-/run/pithead-restore}"; }

# Setup accepts the appliance backup layout, never arbitrary host paths from an archive.
# Trailing slashes name data trees; other entries name individual files. Keep the same list
# for membership checks and application so a newly accepted item cannot escape the mapping.
restore_setup_config_path() {
    case "$CONFIG_FILE" in
    /*) printf '%s\n' "$CONFIG_FILE" ;;
    *) printf '%s\n' "$PWD/$CONFIG_FILE" ;;
    esac
}

restore_setup_items() {
    printf '%s\n' "$(restore_setup_config_path)" "$PWD/$ENV_FILE" "$PWD/Caddyfile" \
        "$PWD/data/tor/" "$PWD/data/dashboard/" "$PWD/data/monero/" \
        "$PWD/data/tari/" "$PWD/data/p2pool/"
}

restore_setup_archive_within_limits() { # <names-file> <verbose-file> [max-members] [max-bytes]
    local members bytes
    members=$(wc -l <"$1")
    [ "$members" -le "${3:-4096}" ] && [ "$(wc -c <"$1")" -le 1048576 ] || return 1
    bytes=$(awk '$1 ~ /^-/ { total += $3 } END { printf "%.0f", total }' "$2")
    [ "$bytes" -le "${4:-1073741824}" ]
}

restore_setup_tar_list() { # <archive> <tar-list-option> <output> [max-KiB] [seconds]
    timeout "${5:-30}" bash -c \
        'ulimit -f "$1"; exec tar --quoting-style=escape "$2" "$3"' \
        _ "${4:-4096}" "$2" "$1" >"$3" 2>/dev/null
}

restore_setup_publish_file() { # <source> <destination>
    local publish
    publish=$(mktemp "${2}.restore.XXXXXXXXXX") || return 1
    if ! install -m 600 "$1" "$publish" || ! mv -fT -- "$publish" "$2"; then
        rm -f -- "$publish"
        return 1
    fi
}

restore_setup_members() { # <tar name listing>
    local member item accepted directory
    while IFS= read -r member; do
        case "$member" in '' | /* | *\\* | . | ./* | */./* | */. | *//* | ../* | */../* | */..) return 1 ;; esac
        directory=0
        [[ "$member" = */ ]] && directory=1
        member="${member%/}"
        accepted=0
        while IFS= read -r item; do
            item="${item#/}"
            if [[ "$item" = */ ]]; then
                [[ "$member" = "$item"* ]] && accepted=1
                [[ "$member" = "${item%/}" && "$directory" = 1 ]] && accepted=1
            elif [ "$member" = "$item" ] && [ "$directory" = 0 ]; then
                accepted=1
            fi
        done < <(restore_setup_items)
        [ "$accepted" = 1 ] || return 1
    done <<<"$1"
}

# The whole restore acceptance, shared by its two doors — the wizard's spool channel
# (firstboot_consume_restore) and the installer-carried ESP pre-seed (consume_preseed_restore):
# size cap, encryption detection, decrypt verification, tar integrity, path-safety audit,
# extract-and-validate through a staging copy, then commit. One set of checks, two doors.
# With <config-only-dest> set, the validated config is copied there and NOTHING ELSE touches
# this machine — the installer flow, where the restored tree belongs to the TARGET and
# decrypted keys must never rest on the stick. rc 0: done. rc 1: refused, one page-ready
# line in <errfile>. Never deletes <archive> — the callers own their files.
restore_apply() ( # <archive> <passphrase> <errfile> [<config-only-dest>]
    local archive="$1" pass="$2" errf="$3" cfg_dest="${4:-}"
    local size magic encrypted=0 tmp plain tree staged_cfg config_path err

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

    tmp=$(mktemp -d "$PWD/.restore.XXXXXXXXXX") || {
        printf 'could not stage the restore' >"$errf"
        return 1
    }
    trap 'rm -rf -- "$tmp"' EXIT
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

    if ! restore_setup_members "$rnames"; then
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
    # use), so the staged config lands at exactly $PWD/$CONFIG_FILE underneath $tmp.
    config_path=$(restore_setup_config_path)
    staged_cfg="$tree$config_path"
    if [ ! -f "$staged_cfg" ] || ! jq -e . "$staged_cfg" >/dev/null 2>&1; then
        rm -rf "$tmp"
        printf 'archive does not contain a usable configuration' >"$errf"
        return 1
    fi
    # Validated through the COPY — parse_and_validate_config fills in generated fields as it
    # goes (consume_preseed_config's own reasoning), and only a config that survives this is
    # ever promoted to the real config.json.
    if ! err=$(PITHEAD_CONFIG_FILE="$staged_cfg" bash -c "source '${BASH_SOURCE[0]}' && parse_and_validate_config" 2>&1); then
        rm -rf "$tmp"
        printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240 >"$errf"
        return 1
    fi

    if [ -n "$cfg_dest" ]; then
        # Installer door: the card and the ESP staging need the config; the tree stays in the
        # archive for the target to restore itself.
        restore_setup_publish_file "$staged_cfg" "$cfg_dest" || {
            printf 'could not apply the backup files' >"$errf"
            return 1
        }
        rm -rf "$tmp"
        return 0
    fi
    if ! restore_canonicalize_derived "$staged_cfg" "$tree$PWD/$ENV_FILE" "$tree$PWD/Caddyfile"; then
        rm -rf "$tmp"
        printf 'archive contains invalid generated identity or secret state' >"$errf"
        return 1
    fi
    # Apply only the accepted files/data trees. Do not copy staging's ancestor directories
    # onto /: their metadata is not part of the backup contract.
    local item source dest copy_failed=0
    while IFS= read -r item; do
        source="$tree$item"
        [ -e "$source" ] || continue
        if [[ "$item" = */ ]]; then
            dest="${item%/}"
            rm -rf -- "$dest"
            mv -T -- "$source" "$dest" || {
                copy_failed=1
                break
            }
        else
            restore_setup_publish_file "$source" "$item" || {
                copy_failed=1
                break
            }
        fi
    done < <(restore_setup_items)
    if [ "$copy_failed" = 1 ]; then
        rm -rf "$tmp"
        printf 'could not apply the backup files' >"$errf"
        return 1
    fi
    rm -rf "$tmp"
    # #1239 (live KVM guest evidence): the archive's .env is the SOURCE machine's own —
    # DEPLOYMENT_COMPLETED=true there records THAT machine's prior deployment, not this
    # hardware's. Both doors that reach here feed straight into a headless `setup()`
    # (firstboot's spool-accept path, the ESP pre-seed door consumed at boot): setup()'s
    # is_deployed guard exists to stop an operator re-running setup on a box that is already
    # live (#924), and it has no way to tell "restored, never provisioned HERE" apart from
    # "live" — a carried true fires that guard's exact fatal, no-tty refusal, and setup never
    # runs: prepare_directories, render_env, provision_tor never fire, no container starts. A
    # just-restored box has NOT completed deployment on this hardware — clear the marker so the
    # caller's setup() actually provisions it. The staged canonicalizer has already retained only
    # validated generated secrets and Tor identity while deriving host and policy from config;
    # this path changes its one hardware-specific lifecycle value. Scoped to THIS commit
    # path on purpose — stack_restore (the admin `./pithead restore` command, for a box already
    # deployed on its own hardware) has its own separate extraction and never calls restore_apply,
    # so a live box's restore keeps its completion marker exactly as it should.
    if [ -f "$PWD/$ENV_FILE" ]; then
        safe_sed 's/^DEPLOYMENT_COMPLETED=.*/DEPLOYMENT_COMPLETED=false/' "$PWD/$ENV_FILE"
    fi
    return 0
)

firstboot_consume_restore() ( # <spool-dir> [<installer 0|1>]
    local spool="$1" installer="${2:-0}" archive pass_snap="" pass="" rc=0 errf
    archive=$(wizard_spool_request "$spool" restore-archive "$RESTORE_MAX_BYTES") || rc=$?
    if [ "$rc" != 0 ]; then
        [ "$rc" = 2 ] || rm -f "$spool/restore-passphrase"
        return "$rc"
    fi
    errf="${archive%/*}/error"
    trap 'rm -f "$errf"; wizard_spool_clean "${archive%/*}"; [ -z "$pass_snap" ] || wizard_spool_clean "${pass_snap%/*}"' EXIT
    { set +x; } 2>/dev/null
    pass_snap=$(wizard_spool_snapshot "$spool" restore-passphrase 4096) || rc=$?
    rm -f "$spool/restore-passphrase" "$spool/restore-archive"
    if [ "$rc" = 0 ]; then
        pass=$(cat "$pass_snap")
    elif [ "$rc" != 2 ]; then
        wizard_spool_publish "$spool" error.txt printf '%s' 'Unsafe restore passphrase file — submit again.'
        return 1
    fi
    # Error text is private too: restore_apply never receives a page-writable path.
    umask 077
    if [ "$installer" -eq 1 ]; then
        if ! restore_apply "$archive" "$pass" "$errf" "$PWD/config.json"; then
            wizard_spool_publish "$spool" error.txt cat "$errf"
            return 1
        fi
        local carry
        carry=$(restore_carry_dir)
        (umask 077 && mkdir -p "$carry" &&
            mv -fT "$archive" "$carry/archive" &&
            printf '%s' "$pass" >"$carry/pass") || {
            wizard_spool_publish "$spool" error.txt printf '%s' 'could not stage the restore for the install'
            rm -rf "$carry" "$PWD/config.json"
            return 1
        }
    elif ! restore_apply "$archive" "$pass" "$errf"; then
        wizard_spool_publish "$spool" error.txt cat "$errf"
        return 1
    fi
    wizard_spool_publish "$spool" applied true
)
