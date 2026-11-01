preseed_target_serials() {
    local f="$PRESEED_DIR/pithead-target-serial.txt" line n=0
    [ -f "$f" ] || return 2
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        if [ "$line" = unknown ] || [[ ! "$line" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
            warn "$f holds a line that is not a usable disk serial — the setup page opens instead."
            return 1
        fi
        printf '%s\n' "$line"
        n=$((n + 1))
    done <"$f"
    [ "$n" -gt 0 ] && return 0
    warn "$f names no disk serial — the setup page opens instead."
    return 1
}

headless_install() { # <spool-dir>
    local spool="$1" serials serial found="" inventory matches="" hit n tmp rc=0 err
    serials=$(preseed_target_serials) || rc=$?
    [ "$rc" = 2 ] && return 2
    [ "$rc" = 0 ] || return 1
    tmp=$(mktemp) || return 1
    consume_preseed_config "$tmp" || rc=$?
    rm -f "$tmp" "${tmp}.bak-1x"
    if [ "$rc" != 0 ]; then
        warn "A disk serial file needs a valid pithead-config.json beside it — the setup page opens instead."
        return 1
    fi
    inventory=$("$(install_bin)" --list 2>/dev/null) || inventory=""
    while IFS= read -r serial; do
        hit=$(printf '%s\n' "$inventory" | awk -F'\t' -v s="$serial" '($4 "") == s {print $1}')
        [ -z "$hit" ] || {
            matches="$matches$hit"$'\n'
            found="$serial"
        }
    done < <(printf '%s\n' "$serials" | sort -u)
    n=$(printf '%s' "$matches" | grep -c . || true)
    if [ "$n" -ne 1 ]; then
        warn "$n offered disks match the serial file — nothing was erased; the setup page opens instead."
        warn "  offered: $(printf '%s\n' "$inventory" | cut -f1,4 | tr '\t\n' ' =' | tr -d '[:cntrl:]' | tail -c 200)"
        return 1
    fi
    mutation_lock_acquire firstboot-install
    log "Installing to the disk with serial $found (data: keep) ..."
    if err=$("$(install_bin)" --target-serial "$found" --wipe keep --yes 2>&1); then
        wizard_install_finish "$(container_engine)" "$spool" "Headless install complete — switching off now." \
            "The disk named by the stick's serial file was installed; its settings come from the stick." || {
            warn "The install finished but the switch-off did not start — switch the machine off by hand."
            mutation_lock_release
        }
        return 0
    fi
    warn "Headless install failed; the named disk may be partly written, so do not boot from it until it is installed again."
    warn "  $(printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240)"
    mutation_lock_release
    return 1
}
