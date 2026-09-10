# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_fault() {
    info "phase: fault injection — a brick is disqualifying, not deducted"
    local img bundle marker i out

    info "building v1 image (marker v1)"
    img=$(_build_image v1) || {
        bad "v1 image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 300 || {
        bad "v1 guest never answered SSH"
        return
    }
    # shellcheck disable=SC2154  # shared through the assembled runner scope
    ok "v1 boots and answers SSH ($ip)"

    info "building v2 bundle (marker v2)"
    bundle=$(_build_bundle v2) || {
        bad "v2 bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    [ -n "$bundle" ] && [ -f "$bundle" ] || {
        bad "no update bundle produced"
        return
    }
    ok "v2 bundle built: $(basename "$bundle")"
    _stage_bundle "$bundle" || {
        bad "staging the bundle on the guest failed"
        return
    }

    # Fault A: cut power WHILE the updater is writing the spare slot. The invariant is not that
    # the update survives — it is that the box still boots something.
    for i in 1 2 3; do
        info "fault A$i — destroy mid-write"
        _ssh "nohup sh -c '$(_install_cmd /data/update.bundle)' >/tmp/inst.log 2>&1 &" || true
        sleep 12
        virsh destroy "$VM" >/dev/null 2>&1 || true
        sleep 3
        virsh start "$VM" >/dev/null 2>&1 || true
        if _wait_ssh 300; then
            marker=$(_marker)
            ok "A$i: survived a mid-write power cut — booted slot marker '$marker'"
        else
            bad "A$i: BRICKED — no boot after a mid-write power cut (disqualifying)"
            return
        fi
    done

    # Fault C: hand the updater a CORRUPTED bundle. Three power cuts just landed on this guest,
    # so a damaged download is exactly what a real box would be holding. The bar is a clean
    # refusal — refusing to install is correct, crashing is not, and bricking is disqualifying.
    info "fault C — install a deliberately corrupted bundle"
    _ssh "dd if=/dev/urandom of=/data/update.bundle bs=1M seek=8 count=2 conv=notrunc" >/dev/null 2>&1 || true
    local corrupt_rc=0
    out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1") || corrupt_rc=$?
    if printf '%s' "$out" | grep -qi "panic"; then
        bad "C: the updater PANICKED on a corrupt bundle instead of refusing it"
        info "  $(printf '%s' "$out" | grep -i panic | head -1 | cut -c1-150)"
    elif [ "$corrupt_rc" -eq 0 ]; then
        # The old check only asserted the absence of "panic" — an install that quietly ACCEPTED
        # the tampered bundle read as a pass. The refusal itself is the assertion.
        bad "C: a corrupted/tampered bundle was ACCEPTED (installer exited 0)"
    else
        ok "C: a corrupt bundle is refused without crashing (exit $corrupt_rc)"
    fi
    if _wait_ssh 300; then
        ok "C: still boots after being handed a corrupt bundle (marker '$(_marker)')"
    else
        bad "C: BRICKED by a corrupt bundle (disqualifying)"
        return
    fi

    # Fault B: cut power during the commit itself, the smallest and most dangerous window.
    # Re-stage first: the bundle on /data has just survived three power cuts and been corrupted
    # on purpose, and this leg is measuring the commit window, not bundle integrity.
    info "installing v2 fully, then destroying mid-commit"
    _stage_bundle "$bundle" || {
        bad "re-staging the bundle before the commit test failed"
        return
    }
    local before
    before=$(_boot_id) || bad "could not read the boot id before the install — a reconnect and a reboot would look alike"
    [ -n "$before" ] || return
    out=$(_ssh "$(_install_and_boot_cmd /data/update.bundle) 2>&1" || true)
    [ -n "$out" ] && info "install output: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
    _wait_new_boot "$before" 300 || {
        bad "guest never returned after installing v2"
        return
    }
    marker=$(_marker)
    if [ "$marker" = "v2" ]; then
        ok "installed update is running (marker v2)"
    else
        bad "expected v2 after installing and booting the spare, got '$marker'"
        return
    fi
    _ssh "nohup sh -c '$(_commit_cmd)' >/tmp/commit.log 2>&1 &" || true
    sleep 1
    virsh destroy "$VM" >/dev/null 2>&1 || true
    sleep 3
    virsh start "$VM" >/dev/null 2>&1 || true
    if _wait_ssh 300; then
        ok "B: survived a mid-commit power cut — booted slot marker '$(_marker)'"
    else
        bad "B: BRICKED — no boot after a mid-commit power cut (disqualifying)"
        return
    fi

    # Operator-initiated rollback: a release can be bad without failing its health check, so the operator must
    # be able to put the previous version back on demand — not only wait for an automatic fallback.
    info "operator-initiated rollback"
    marker=$(_marker)
    if _reboot_wait "$(_rollback_cmd)" 300; then
        local after
        after=$(_marker)
        if [ -n "$after" ] && [ "$after" != "$marker" ]; then
            ok "operator rollback works on demand ($marker -> $after)"
        else
            bad "operator rollback did not change the running slot (still '$after')"
        fi
    else
        bad "guest did not return after an operator-initiated rollback"
        return
    fi

    # The box must still be updatable afterwards, not merely alive. Commit first: an operator who
    # has just rolled back to a known-good version would mark it good before updating again, and
    # Rugix correctly refuses to install onto a system that has not yet verified its own boot
    # ("system needs to be committed before installing an update"). Skipping the commit tested an
    # operator nobody is, and scored a safety feature as a failure.
    local out
    _ssh "$(_commit_cmd)" >/dev/null 2>&1 || true
    if out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1"); then
        ok "still updatable after fault injection"
    else
        bad "no longer accepts an update after fault injection"
        printf '%s\n' "$out" | tail -12 | sed 's/^/       /'
    fi
}

# The last-resort path — never yet run against a real disk. Two legs, opt-in (destructive, and
# the recovery leg re-partitions/re-mounts a disk out from under a running guest).
#
#   leg 1  a PROVISIONED machine runs `pithead factory-reset -y` — the real command, not a
#          reimplementation of it — which arms the `pithead-reset` marker on the ESP
#          ($PRESEED_DIR/pithead-reset, default /boot/efi) and reboots. pithead-data-reset picks
#          the marker up before /data mounts, reformats it, and consumes the marker. Assert the
#          machine comes back to the wizard without bricking, the provisioned config and old
#          container images are gone, and — the reset-tier rule — host identity (SSH host-key
#          fingerprint, machine-id) is FRESH, not carried over: a handed-over box must not keep
#          the old owner's identity (os/overlay/pithead-data-reset). The reseed directive itself
#          (systemd-repart's MakeDirectories= for the overlay/var upperdirs and /pithead) is
#          proven statically against the built image in tests/os/verify-image.sh (#1092) — a
#          post-boot dir check here cannot observe a dropped entry honestly (see the comment at
#          the assertion site below).
#   leg 2  the OTHER trigger: a data partition that will not mount even after fsck. Corrupt the
#          ext4 magic on partition 4 (the fixed data slot) from the HOST, on the powered-off
#          disk, then boot and assert the box self-heals into the wizard instead of bricking.
