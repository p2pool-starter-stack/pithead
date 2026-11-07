# --- OS update (appliance A/B slots) ---

os_running_variant() { # echoes debug|release|unknown
    local v
    v=$(tr -d ' \t\r\n' 2>/dev/null <"${PITHEAD_VARIANT_FILE:-/etc/pithead-variant}" || true)
    case "$v" in debug | release) echo "$v" ;; *) echo unknown ;; esac
}

os_bundle_meta() { # $1: bundle, $2: [meta.pithead] key — echoes its value or empty, never fails
    # `rauc info --output-format=shell` is the one machine-readable format that carries the
    # manifest's [meta.*] sections on the RAUC the appliance actually ships (1.11's JSON output
    # OMITS them entirely — the json parser here read real bundles as unstamped, found by the
    # tier-4 migration leg). Verification still runs: rauc info checks the bundle signature
    # against the system keyring before printing anything. Anything unparseable degrades to
    # empty, which every consumer treats as fail-closed "unstamped".
    #
    # `|| true` on rauc's own leg: under `set -o pipefail` a signature failure makes rauc info
    # exit nonzero, and that alone — with sed/head both still succeeding on empty input — fails
    # the whole pipe. In a bare `var=$(os_bundle_meta ...)` assignment that trips `set -e` right
    # here, before any caller sees a result, which is exactly this function's own "never fails"
    # contract broken by pipefail (#1041: the actual mechanism behind the ERR trap's contentless
    # "aborted unexpectedly" — os_update's callers below never got a chance to run at all).
    { rauc info --output-format=shell "$1" 2>/dev/null || true; } |
        sed -n "s/^RAUC_META_PITHEAD_$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')='\(.*\)'\$/\1/p" |
        head -1
}

os_bundle_variant() { # $1: bundle path — echoes debug|release|unknown, never fails
    # Unknown covers both an unstamped bundle and any garbage: the gate treats unknown as
    # shell-less, so a debug box is warned before an install that might drop SSH.
    local v
    v=$(os_bundle_meta "$1" variant)
    case "$v" in debug | release) echo "$v" ;; *) echo unknown ;; esac
}

os_semver_ok() { printf '%s' "${1:-}" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; }

os_running_version() { # the OS version this checkout/slot IS — PITHEAD_VERSION, else the VERSION file
    printf '%s' "${PITHEAD_VERSION:-$(tr -d ' \t\r\n' <VERSION 2>/dev/null || true)}"
}

# The /data-resident floor: the lowest OS version that can still read the current on-disk chain
# data. Raised when a data_migration bundle installs; read back to refuse an unsafe rollback below
# it. Overridable for tests; absent means no migration has raised a floor yet (today's reality).
os_data_floor_file() { printf '%s' "${PITHEAD_DATA_FLOOR_FILE:-/data/pithead/.os-data-floor}"; }

os_data_floor() { # echoes the floor version, or empty
    local f
    f=$(os_data_floor_file)
    [ -f "$f" ] && tr -d ' \t\r\n' <"$f" 2>/dev/null || true
}

os_migration_write() {
    local temporary
    mkdir -p "$(dirname "$1")" || return 1
    temporary=$(mktemp "$1.XXXXXX") || return 1
    if ! { printf '%s\n' "$2" >"$temporary" && chmod 0644 "$temporary" &&
        sync -f "$temporary" && mv -f "$temporary" "$1" && sync -f "$1"; }; then
        rm -f "$temporary"
        return 1
    fi
}

os_raise_data_floor() { # $1: new floor, $2: optional slot-specific install intent
    local f cur
    f=$(os_data_floor_file)
    cur=$(os_data_floor)
    os_migration_write "$f.prev" "${cur:-none}" || return 1
    if [ -n "${2:-}" ]; then
        os_migration_write "$(os_migration_marker_file)" "$2" || return 1
    fi
    if [ -z "$cur" ] || { os_semver_ok "$cur" && semver_newer "$1" "$cur"; }; then
        os_migration_write "$f" "$1" || return 1
    fi
}

os_migration_marker_file() { printf '%s' "${PITHEAD_MIGRATION_MARKER_FILE:-/data/pithead/.os-migration-pending}"; }

os_migration_fingerprint() {
    local marker
    marker=$(os_migration_marker_file)
    [ -f "$marker" ] || return 0
    stat -Lc '%d:%i:%y:%z' "$marker" && cat "$marker"
}

os_restore_prepared_migration() {
    local f marker prev
    f=$(os_data_floor_file)
    marker=$(os_migration_marker_file)
    if [ -f "$f.prev" ]; then
        prev=$(tr -d '[:space:]' <"$f.prev") || return 1
        if [ "$prev" = none ]; then
            rm -f "$f" && sync || return 1
        else
            os_semver_ok "$prev" && os_migration_write "$f" "$prev" || return 1
        fi
    fi
    rm -f "$marker" "$f.prev" && sync
}

os_disarm_prepared_migration() {
    local status marker slot
    slot=$(os_booted_slot) || return 1
    marker=$(tr -d '[:space:]' <"$(os_migration_marker_file)") || return 1
    case "$marker" in
    *'|'*) [ "${marker#*|}" != "$slot" ] || return 1 ;;
    esac
    status=$(rauc status --output-format=json) || return 1
    jq -e --arg slot "$slot" \
        '[.slots[] | .[] | select(.state == "booted" and .bootname == $slot and .boot_status == "good")] | length == 1' \
        <<<"$status" >/dev/null || return 1
    rauc status mark-bad other && sync && os_restore_prepared_migration
}

os_booted_slot() {
    tr ' ' '\n' <"${PITHEAD_CMDLINE:-/proc/cmdline}" | sed -n 's/^rauc\.slot=\([AB]\)$/\1/p'
}

os_migration_hold_active() {
    local f v slot
    f=$(os_migration_marker_file)
    [ -f "$f" ] || return 1
    v=$(tr -d ' \t\r\n' <"$f") || return 2
    case "$v" in
    '' | *[!0-9.vAB\|]*) return 2 ;;
    esac
    os_semver_ok "${v%%|*}" || return 2
    case "$v" in
    *'|'*)
        case "${v#*|}" in A | B) ;; *) return 2 ;; esac
        slot=$(os_booted_slot) || return 2
        case "$slot" in A | B) ;; *) return 2 ;; esac
        [ "${v#*|}" = "$slot" ] || return 1
        [ "${v%%|*}" = "$(os_running_version)" ] || return 2
        ;;
    *) [ "$v" = "$(os_running_version)" ] ;;
    esac
}

os_prepare_migration_hold() { # 0 hold, 1 fallback/absent, 2 cannot establish ownership
    local rc slot marker
    os_migration_hold_active && rc=0 || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    slot=$(os_booted_slot) || return 2
    case "$slot" in A | B) ;; *) return 2 ;; esac
    marker=$(os_migration_marker_file)
    os_migration_write "$marker" "$(os_running_version)|$slot" || return 2
    printf 'pithead-boot: migration marker claimed: %s|%s\n' "$(os_running_version)" "$slot"
}

# The version floor + downgrade refusals, shared verbatim by the `os-update` CLI and the
# dashboard's os-verify/os-install control verbs so the two doors can never drift apart. Echoes
# the refusal reason (empty = pass). A correctly-signed bundle is not automatically a safe one:
# an OLDER image re-introduces the holes the newer one fixed under our own signature, and an
# image below the /data migration floor cannot read the chain data a newer release migrated.
# Both guards fail CLOSED: a version the comparator cannot parse (a pre-release/-prep suffix,
# garbage, or an absent stamp) is not proof of safety, so it refuses rather than skips.
# semver_newer only understands clean X.Y.Z, so os_semver_ok gates every comparison.
os_update_version_guard() { # $1: bundle version, $2: allow_downgrade 0|1 — echoes refusal or nothing
    local bundle_version="$1" allow_downgrade="${2:-0}" running_version floor_file floor
    running_version=$(os_running_version)

    # The data floor is not a policy knob — installing below it strands the migrated chain data,
    # so it refuses with no override. A floor FILE that exists is authoritative: a corrupt or
    # unparseable floor, or a bundle we cannot prove is at or above it, refuses. The escape is a
    # factory reset or restoring a matching backup.
    floor_file=$(os_data_floor_file)
    if [ -f "$floor_file" ]; then
        floor=$(os_data_floor)
        if ! os_semver_ok "$floor"; then
            printf '%s' "Refusing: the /data migration floor is unreadable ('${floor:-empty}'). A corrupt floor is not permission to install over migrated chain data — restore it, or recover with a factory reset (loses the chain) or a matching backup."
            return 0
        fi
        # A floor ABOVE the running version cannot be what it claims (#1393): a slot that could not
        # read /data would not be running. Either a migrating update failed its gate and fell back
        # before its migration ran, with the floor never put back (the data is untouched), or this
        # slot was installed outside pithead below migrated data. The guard lowers nothing — only
        # pithead-boot does, with a record — so it refuses with the true premise and the open
        # route, and never names a reset or a restore as the way out of this state.
        if os_semver_ok "$running_version" && semver_newer "$floor" "$running_version" &&
            { ! os_semver_ok "$bundle_version" || semver_newer "$floor" "$bundle_version"; }; then
            printf '%s' "Refusing: the /data floor says OS >= $floor is needed to read the chain data, yet this slot runs $running_version — either a migrating update to $floor failed its gate and fell back before its migration ran (the chain data is untouched, and the floor was never put back), or this slot was installed outside pithead below migrated data. This bundle is '${bundle_version:-unstamped}'; the floor version or newer installs. Nothing needs resetting or restoring for this."
            return 0
        fi
        if ! os_semver_ok "$bundle_version" || semver_newer "$floor" "$bundle_version"; then
            printf '%s' "Refusing: /data was migrated forward and now needs OS >= $floor to read; this bundle is '${bundle_version:-unstamped}'. Installing it would strand the chain data. Recover with a factory reset (loses the chain) or by restoring a backup taken on $floor or newer."
            return 0
        fi
    fi

    # Downgrade guard: install without --allow-downgrade ONLY when the bundle is a clean release
    # semver provably newer than or equal to the running one. An older, pre-release, or unstamped
    # bundle re-opens fixed holes under a valid signature — it needs the explicit flag. Skipped
    # only when we cannot read our OWN version (a source checkout; os-update is appliance-only in
    # practice, where the running version is always the baked release stamp).
    if os_semver_ok "$running_version" &&
        { ! os_semver_ok "$bundle_version" || semver_newer "$running_version" "$bundle_version"; }; then
        if [ "$allow_downgrade" -eq 0 ]; then
            printf '%s' "Refusing a possible downgrade: bundle version '${bundle_version:-unstamped}', running $running_version. Only a clean X.Y.Z release at or newer than the running one installs without confirmation. Pass --allow-downgrade to install an older, pre-release, or unstamped bundle on purpose."
            return 0
        fi
    fi
    return 0
}

# The room a data-migrating update needs on the Tari data volume (#2645). A data_migration bundle
# releases the chain services once its slot commits, and a Tari major then migrates the node
# database by writing a compacted copy beside the old one. On a volume without that room the
# migration fails part-way, after the update has committed, so the install refuses first. Sized
# and worded as `pithead upgrade` does it (tari_db_space_shortfall, #2636), and shared by the
# `os-update` CLI and the dashboard's os-verify/os-install verbs like the floor guard above. It
# keys on the data_migration flag alone: the Tari image the bundle ships is in its compose file,
# which cannot be read before the install. A node that is not local runs no migration here; a
# size or free space that cannot be read is a warning, not a refusal. Echoes the refusal, or
# nothing.
os_update_migration_space_guard() { # $1: the bundle's data_migration value
    local db sizes rc=0
    [ "$1" = "true" ] || return 0
    case "$(env_get TARI_MODE)" in off | remote) return 0 ;; esac
    db=$(tari_local_db_file) || return 0
    sizes=$(tari_db_space_shortfall "$db") || rc=$?
    case "$rc" in
    1) printf '%s' "Refusing: this update declares a chain data migration, which runs once it commits. A Tari major migration writes a compacted copy of the node database beside the old one, and whether this update carries one cannot be read before it installs, so it needs $sizes. Free space there, then retry. Nothing was installed." ;;
    2) warn "Could not read the size of $db or the free space on its volume, so the space a Tari major migration would need was not checked." ;;
    esac
    return 0
}

os_update_needs_confirmation() { # $1: running variant, $2: bundle variant — rc 0 = confirm first
    # Consent is needed whenever an install flips the box's shell/SSH posture, in EITHER direction,
    # or when the bundle's posture can't be verified. A debug image bakes a standing root
    # authorized_keys + sshd; a release image is shell-less by design.
    #   - GAIN a shell (#854): a debug bundle onto a box that isn't already debug enables root SSH.
    #     "About to gain a management channel" needs consent as much as losing one — more so.
    #   - LOSE the shell (#819): a release/unstamped bundle onto a debug box removes the channel
    #     that is probably driving this very update; recovery then needs a console on the box.
    #   - UNVERIFIED: an unstamped bundle degrades to "unknown" and could silently BE a debug build
    #     (unparseable stamp), so never wave one through unprompted.
    local running="$1" bundle="$2"
    [ "$bundle" = "debug" ] && [ "$running" != "debug" ] && return 0 # gaining a shell
    [ "$running" = "debug" ] && [ "$bundle" != "debug" ] && return 0 # losing the shell
    [ "$bundle" = "unknown" ] && return 0                            # unverified bundle
    return 1
}

os_update() {
    local bundle="" assume_yes=0 allow_downgrade=0 do_reboot=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        --allow-downgrade) allow_downgrade=1 ;;
        --reboot) do_reboot=1 ;;
        -*) error "Unknown option for os-update: $arg. Run '$0 help'." ;;
        *)
            [ -z "$bundle" ] || error "os-update takes exactly one bundle path. Run '$0 help'."
            bundle="$arg"
            ;;
        esac
    done
    [ -n "$bundle" ] || error "os-update needs the path to an update bundle (.raucb). Run '$0 help'."
    command -v rauc >/dev/null 2>&1 ||
        error "rauc is not available here — OS updates apply to the appliance image, not a checkout install."
    [ -f "$bundle" ] || error "No such bundle: $bundle"

    # Verify the bundle explicitly, before anything reads its metadata (#1041). `rauc info`
    # checks the signature against the system keyring before it prints anything, so a bad
    # signature fails right here with RAUC's own precise diagnosis on stderr (e.g. "signature
    # verification failed: Verify error: self-signed certificate" — a bundle signed by a chain
    # this machine doesn't trust). Captured explicitly rather than left to whatever later reads
    # the bundle: the dashboard's os-verify/os-install doors already run this same check
    # (os_verify_bundle_reason) before this CLI path ever runs, but the CLI's own os-update had
    # nothing playing that role, so its ERR trap fired with no diagnosis to show for it.
    local rauc_info_err rauc_rc=0
    rauc_info_err=$(rauc info "$bundle" 2>&1 >/dev/null) || rauc_rc=$?
    if [ "$rauc_rc" -ne 0 ]; then
        error "rauc could not verify this bundle.${rauc_info_err:+ rauc said: $(printf '%s' "$rauc_info_err" | tail -1 | tr -d '[:cntrl:]' | head -c 300)}"
    fi

    # Version floor + data-migration guards — the exact refusals the dashboard's os-verify/
    # os-install verbs run (os_update_version_guard and os_update_migration_space_guard, shared
    # so the two doors never drift).
    local bundle_version bundle_min bundle_migrates running_version guard_reason
    bundle_version=$(os_bundle_meta "$bundle" version)
    bundle_min=$(os_bundle_meta "$bundle" minimum_os_version)
    bundle_migrates=$(os_bundle_meta "$bundle" data_migration)
    running_version=$(os_running_version)
    guard_reason=$(os_update_version_guard "$bundle_version" "$allow_downgrade")
    [ -z "$guard_reason" ] || error "$guard_reason"
    guard_reason=$(os_update_migration_space_guard "$bundle_migrates")
    [ -z "$guard_reason" ] || error "$guard_reason"
    if [ "$allow_downgrade" -eq 1 ] && os_semver_ok "$running_version" &&
        { ! os_semver_ok "$bundle_version" || semver_newer "$running_version" "$bundle_version"; }; then
        warn "Installing a bundle that is not a verified upgrade (version '${bundle_version:-unstamped}', running $running_version) — downgrade explicitly allowed."
    fi

    local running target
    running=$(os_running_variant)
    target=$(os_bundle_variant "$bundle")
    if os_update_needs_confirmation "$running" "$target"; then
        if [ "$target" = "debug" ]; then
            # Gaining a shell — only reached when the running variant is not already debug (#854).
            warn "This bundle is a DEBUG build: it bakes in a standing root SSH key and enables sshd."
            warn "Installing it turns this shell-less box into one with a permanent root SSH backdoor."
        elif [ "$running" = "debug" ]; then
            # Losing the shell (#819): a release/unstamped bundle onto a debug box.
            warn "This system is a debug build: SSH is baked in, and it is probably the channel driving this update."
            if [ "$target" = "release" ]; then
                warn "The bundle is a release build — shell-less by design. Installing it removes SSH; recovery then needs a console on the box."
            else
                warn "The bundle carries no variant stamp — treat it as a shell-less release build. Installing it can remove SSH; recovery then needs a console on the box."
            fi
        else
            # Unverified bundle onto a non-debug box: an unparseable stamp could hide a debug build.
            warn "The bundle carries no variant stamp — its shell/SSH posture can't be verified, and it may enable root SSH. Recovery may need a console on the box."
        fi
        if [ "$assume_yes" -eq 0 ]; then
            read -r -p "Install it anyway? (y/N): " CONFIRM || true
            if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                log "OS update cancelled."
                return 1
            fi
        fi
    fi
    mutation_lock_acquire os-update
    local marker candidate migration_rc=0
    marker=$(os_migration_marker_file)
    if [ "$bundle_migrates" = true ]; then
        os_semver_ok "$bundle_version" && os_semver_ok "$bundle_min" ||
            error "A migrating bundle needs a valid version and minimum OS version; the OS update was not started."
    fi
    if [ "$bundle_migrates" = true ] || [ -f "$marker" ]; then
        candidate=$(os_booted_slot) || candidate=""
        case "$candidate" in
        A) candidate=B ;;
        B) candidate=A ;;
        *) error "Cannot establish the booted A/B slot; the OS update was not started." ;;
        esac
    fi
    if [ -f "$marker" ]; then
        os_migration_hold_active || migration_rc=$?
        [ "$migration_rc" = 1 ] || error "A migration is pending for this boot or its ownership is unreadable; finish the boot before installing another update."
        os_disarm_prepared_migration || error "Could not disarm the previous migration candidate; its protection was retained and the OS update was not started."
    fi
    guard_reason=$(os_update_version_guard "$bundle_version" "$allow_downgrade")
    [ -z "$guard_reason" ] || error "$guard_reason"
    if [ "$bundle_migrates" = true ]; then
        if ! os_raise_data_floor "$bundle_min" "$bundle_version|$candidate"; then
            error "Could not persist migration protection; the OS update was not started and any prepared protection was retained."
        fi
        log "Recorded /data migration floor: OS >= $bundle_min required to read chain data after this update commits."
        log "Marked a data migration pending: the candidate's chain services start only after its slot commits."
    fi
    log "Installing OS update bundle: $bundle (running: $running, bundle: $target)"
    local rauc_log
    rauc_log=$(mktemp)
    if rauc install "$bundle" 2>&1 | tee "$rauc_log"; then
        rm -f "$rauc_log"
        if command -v pithead-boot-version >/dev/null 2>&1; then
            pithead-boot-version record-installed "$bundle_version" || warn "The update installed, but its boot-menu version could not be recorded; the new slot will repair it when it boots."
        fi
    else
        rauc_rc=${PIPESTATUS[0]}
        if [ "$bundle_migrates" = true ]; then
            if [ "$rauc_rc" != 1 ] || ! os_disarm_prepared_migration; then
                warn "The migration candidate could not be safely reconciled; its protection was retained until boot recovery."
            fi
        fi
        local rauc_detail
        rauc_detail=$(grep -aE '^LastError: |^\[ERROR\] |[Ff]ailed' "$rauc_log" 2>/dev/null |
            tail -1 | tr -d '[:cntrl:]' | head -c 300) || rauc_detail=""
        rm -f "$rauc_log"
        error "rauc install failed.${rauc_detail:+ rauc said: $rauc_detail}"
    fi

    mutation_lock_release

    # #2382: 'succeeded' alone left a first-time operator guessing what to do next. The install
    # only wrote the spare slot — mining keeps running the version it always was — so the state
    # and the one command that finishes the job need to be said, not implied.
    log "Installed ${bundle_version:-the bundle} to the spare slot; this machine keeps running ${running_version:-the current version} until it reboots."
    log "Reboot to boot ${bundle_version:-the new version} and commit it — it stays only if the stack comes up healthy, otherwise the next boot falls back. Run '${PITHEAD_REBOOT_CMD:-systemctl reboot}', or '$0 os-update --reboot'."
    if [ "$do_reboot" -eq 1 ]; then
        if [ "$assume_yes" -eq 0 ]; then
            read -r -p "Reboot now? (y/N): " CONFIRM || true
            if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                log "Not rebooting. Run '$0 os-update --reboot' or '${PITHEAD_REBOOT_CMD:-systemctl reboot}' when you're ready."
                return 0
            fi
        fi
        log "Rebooting..."
        ${PITHEAD_REBOOT_CMD:-systemctl reboot} ||
            warn "Reboot command failed — reboot the machine by hand to finish the update."
    fi
}
