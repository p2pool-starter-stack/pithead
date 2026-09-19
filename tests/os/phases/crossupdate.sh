# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

# Cross-version update (#2056): the `update` phase's legs build BOTH A/B slots from THIS tree
# with different markers, so they prove the updater mechanism (the A/B swap, the commit decision,
# rollback, identity survival) but nothing that only differs between two real releases — a
# config/state schema migration, a unit added/renamed/removed, a /data layout change, or a
# `pithead` CLI change that assumes on-disk state an older version never wrote. This phase starts
# from a REAL prior build instead of the same tree: bench-ci's tier4-kvm `options.old_image: true`
# resolves the newest appliance image cached for a commit strictly older than the one under test
# (a nightly `develop` run leaves one behind every day) and hands it here as $PITHEAD_OLD_IMAGE,
# alongside the candidate this job already built for its own commit. Once 2.0.0 exists, the old
# slot becomes the published release image instead — see docs/dev/testing-strategy.md.
#
# Deliberately NOT in the `all` arm below: it needs $PITHEAD_OLD_IMAGE, which only a job that
# requested `options.old_image: true` carries: an `all` run wants every phase to work from the
# image it was given alone.
phase_crossupdate() {
    info "phase: crossupdate (a provisioned N-1 guest upgraded to the candidate built from HEAD)"
    local old="${PITHEAD_OLD_IMAGE:-}"
    [ -n "$old" ] && [ -f "$old" ] || {
        bad "PITHEAD_OLD_IMAGE not set or not a file — this phase needs bench-ci's tier4-kvm options.old_image (docs/dev/testing-strategy.md)"
        return
    }

    info "booting the old appliance image ($old)"
    _vm_boot_disk "$old" && _wait_ssh 900 || {
        bad "the old-version guest never answered SSH (ip: ${ip:-none}; $(_ssh_unreachable_reason "$ip"))"
        return
    }
    ok "old-version guest boots and answers SSH ($ip)"

    info "provisioning the old-version guest through its real wizard"
    _wizard_provision_capture 0 || {
        bad "provisioning the old-version guest failed ($WIZ_FAIL_REASON)"
        return
    }
    ok "old-version guest provisioned (dashboard login captured)"
    local old_user="$DASH_USER" old_pass="$DASH_PASS"

    local deadline=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ok "old-version stack containers are running" ;;
    *)
        bad "old-version stack never came up — running: '${names:-none}'"
        return
        ;;
    esac

    local id_old hostkey_fp_old
    id_old=$(_ssh cat /etc/machine-id)
    hostkey_fp_old=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    if _ssh "grep -q \"$HARNESS_WALLET\" /data/pithead/config.json"; then
        ok "old-version config carries the submitted wallet"
    else
        bad "old-version config does not carry the submitted wallet"
    fi

    info "building the candidate update bundle from the commit under test"
    local bundle
    bundle=$(_build_bundle candidate) || {
        bundle_build_evidence
        bad "candidate bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    ok "built candidate bundle: $(basename "$bundle")"

    _stage_bundle "$bundle" || {
        bad "staging the candidate bundle on the old-version guest failed"
        return
    }
    local out rc
    out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1")
    rc=$?
    [ -n "$out" ] && printf '     install output: %s\n' "$(printf '%s' "$out" | tail -5)"
    [ "$rc" -eq 0 ] || {
        bad "installing the candidate onto the old-version guest failed"
        return
    }
    ok "candidate installed into the spare slot"

    # Boot the candidate: RAUC arms the GRUB try-counter at install, so a plain reboot lands on
    # the spare slot (core.sh's own note on _boot_spare_cmd). This is the ONLY harness-driven
    # reboot left in this leg — it puts the candidate in charge of its own boot, nothing more.
    _reboot_wait "$(_boot_spare_cmd)" 300 || {
        bad "guest never returned after booting the candidate slot"
        return
    }

    # NO harness mark-good, and no harness reboot after it (#2056 review, round 2): on a
    # PROVISIONED machine the product owns the commit decision. pithead-boot's gate requires BOTH
    # signals — the stack SERVING and `pithead doctor --json` passing — before it runs
    # `rauc status mark-good` itself (os/overlay/pithead-boot). A harness commit pre-empts that
    # decision and can interrupt the gate mid-loop, which would make this leg prove the updater
    # mechanism again instead of the thing it exists for: that the candidate converges on state an
    # older version wrote. So wait out the product's terminal verdict and assert on THAT — the same
    # shape as the rig leg's self-commit assertion, read off the same grubenv record. The gate loops
    # 90x10s after its own `pithead up`, so the budget here is deliberately generous.
    info "waiting for pithead-boot's own commit gate (serving + doctor) to reach a terminal verdict"
    local genv="" boot_verdict="" gate_tries=0
    while [ "$gate_tries" -lt 150 ]; do
        genv=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv" in *B_OK=1*B_TRY=0* | *B_TRY=0*B_OK=1*) break ;; esac
        # The other terminal state: the gate gave up, said so on the console, and rebooted to fall
        # back — so the line belongs to this boot or to the one before it.
        boot_verdict=$(_ssh "{ journalctl -b -u pithead-boot --no-pager -o cat; journalctl -b -1 -u pithead-boot --no-pager -o cat; } 2>/dev/null | grep -a 'slot left uncommitted' | tail -1" 2>/dev/null | tr -d '\r')
        [ -n "$boot_verdict" ] && break
        sleep 10
        gate_tries=$((gate_tries + 1))
    done
    case "$genv" in
    *B_OK=1*B_TRY=0* | *B_TRY=0*B_OK=1*)
        ok "pithead-boot's gate committed the candidate slot itself (B_OK=1 B_TRY=0) — serving + doctor, no harness hands"
        ;;
    *)
        bad "the candidate slot was never committed by pithead-boot's gate${boot_verdict:+ — it reported: $boot_verdict} (grubenv: ${genv:-unreadable})"
        # What the gate's own doctor run held on: it writes each round's verdict to /run, so the
        # last one names the blocking check rather than leaving "never committed" unexplained.
        info "  gate doctor fails: $(_ssh "jq -r '[.checks[]? | select(.status==\"fail\") | .message] | join(\"; \")' /run/pithead-boot-doctor.json" 2>/dev/null | tr -d '\r' | cut -c1-300)"
        return
        ;;
    esac

    local marker
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "candidate" ] && ok "the candidate slot is booted (marker: candidate)" ||
        bad "expected the candidate marker after the update, got '${marker:-none}'"

    local id_new hostkey_fp_new
    id_new=$(_ssh cat /etc/machine-id)
    hostkey_fp_new=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    if [ -n "$id_old" ] && [ "$id_old" = "$id_new" ]; then
        ok "machine-id survived the cross-version update ($id_old)"
    else
        bad "machine-id changed across the cross-version update (old: ${id_old:-none}, new: ${id_new:-none})"
    fi
    if [ -n "$hostkey_fp_old" ] && [ "$hostkey_fp_old" = "$hostkey_fp_new" ]; then
        ok "SSH host-key fingerprint survived the cross-version update ($hostkey_fp_old)"
    else
        bad "SSH host-key fingerprint changed across the cross-version update (old: ${hostkey_fp_old:-none}, new: ${hostkey_fp_new:-none})"
    fi

    # Persistence half: the file the OLDER version wrote is still on /data after a whole-slot
    # replacement. On its own this proves only that the slot swap left /data alone (#1091's lesson:
    # a grep of a config file is not proof anything RUNS it), so the runtime half follows.
    if _ssh "grep -q \"$HARNESS_WALLET\" /data/pithead/config.json"; then
        ok "the config the old version wrote survived the slot swap"
    else
        bad "the config the old version wrote did not survive the slot swap"
    fi

    # Runtime half: the --wallet the CANDIDATE's own start path rendered into the p2pool container,
    # read back out of live state with `podman inspect`. That is the older version's configuration
    # being honoured by new code, which is the whole point of a cross-version leg. Same verdict
    # helper (and same reasoning) the restore leg uses, so it is fixture-tested at tier 1.
    names=""
    deadline=$(($(date +%s) + 900))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    local live_wallet="" wdeadline verdict
    wdeadline=$(($(date +%s) + 180))
    while [ "$(date +%s)" -lt "$wdeadline" ]; do
        live_wallet=$(_ssh "podman inspect p2pool --format '{{json .Config.Cmd}}'" 2>/dev/null | jq -r 'index("--wallet") as $i | if $i == null then "" else .[$i+1] // "" end')
        [ -n "$live_wallet" ] && [ "$live_wallet" != "Unknown" ] && [ "$live_wallet" != "null" ] && break
        sleep 10
    done
    if verdict=$(restore_live_state_verdict "$names" "$live_wallet" "$HARNESS_WALLET"); then
        ok "post-update runtime config: $verdict"
    else
        bad "post-update runtime config: $verdict"
        stack_never_up_evidence # #2043: the guest is recycled next, so ask it now
    fi

    # The COMPLETE stack, judged by the product's own contract instead of a hand-written container
    # list: `pithead doctor --json` is the exact command the boot gate runs, and it REFUSES a slot
    # whose revenue containers are down while caddy keeps serving (#852). Sync-held miners (#35) are
    # not failures to it, so this stays honest on a freshly converged guest rather than demanding a
    # synced chain the leg cannot reach.
    if _ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json >/dev/null 2>&1"; then
        ok "the converged candidate passes the product's own doctor contract (the complete stack, not just a boot)"
    else
        bad "doctor refuses the converged candidate stack: $(_ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json 2>/dev/null | jq -r '[.checks[]? | select(.status==\"fail\") | .message] | join(\"; \")'" 2>/dev/null | tr -d '\r' | cut -c1-300)"
    fi

    # Transient healthcheck ephemera excluded, same as the reboot leg's check (provision-reboot.sh):
    # podman drives container healthchecks through hash-named systemd-run units, and one dies
    # harmlessly whenever compose recreates its container mid-check.
    local failed_units
    failed_units=$(_ssh "systemctl --failed --no-legend --no-pager --plain" 2>/dev/null |
        awk '$1 !~ /^[0-9a-f]{64}-[0-9a-f]+\.service$/' | tr -s ' ' | tr '\n' ';')
    if [ -z "${failed_units//[; ]/}" ]; then
        ok "no unit left failed after the cross-version update"
    else
        bad "unit(s) failed after the cross-version update: $failed_units"
    fi

    # Deterministic, not a 360s HTTP poll (#2056 review, round 3): job 360 spent its whole marker
    # budget getting "nothing" back from /static/os-test-marker.txt while the dashboard was
    # provably serving authenticated requests one second later — the static-file route through
    # Caddy/TLS was the wrong instrument for what this actually needs to prove, which is whether
    # `pithead-boot`'s loader-then-`up` sequence (11-baked-images.sh: "'up' recreates on the
    # image-id change") really recreated the container. Ask podman directly, the same
    # runtime-over-archive preference the restore leg's verdict already uses.
    local running_img baked_img tagged_img
    # The reference is what the CANDIDATE SLOT SHIPS, never what happens to sit in podman's store
    # (#2056 review): reading the "loaded" id back out of `podman images` compares the container
    # against itself, so a `load-images` that no-ops leaves the OLD image under that same constant
    # tag and the comparison still matches — exactly the #798 shape this row exists to catch. The
    # slot's own baked archive is the independent anchor: its embedded config digest is the id
    # podman assigns on load, so a container still running the previous version cannot match it.
    # manifest.json sits at the end of a `docker save` tar, so this decompresses the archive once.
    running_img=$(_ssh "podman inspect dashboard --format '{{.Image}}'" 2>/dev/null | tr -d '\r\n')
    baked_img=$(_ssh "tar -xzOf \$(ls /opt/pithead/images/*.tar.gz | head -1) manifest.json 2>/dev/null | jq -r '.[0].Config // \"\"'" 2>/dev/null |
        sed 's#.*/##; s#\.json$##' | tr -d '\r\n')
    # Diagnostic only: a mismatch then says WHICH half did not happen — the loader, or the recreate.
    tagged_img=$(_ssh "podman images --no-trunc --format '{{.Repository}} {{.ID}}'" 2>/dev/null |
        awk '/pithead-dashboard/{print $2; exit}' | tr -d '\r\n')
    tagged_img="${tagged_img#sha256:}"
    if [ -z "$baked_img" ]; then
        bad "could not read the candidate slot's baked dashboard image digest out of /opt/pithead/images — this row has no reference to compare the running container against"
    elif [ -n "$running_img" ] && [ "$running_img" = "$baked_img" ]; then
        ok "the dashboard container is running the image the candidate slot ships ($baked_img)"
    else
        bad "the dashboard container is not running the candidate slot's baked image — a stale container reads as healthy everywhere else (#798) (running: ${running_img:-none}, slot ships: $baked_img, store holds under the tag: ${tagged_img:-none})"
    fi

    local scode
    scode=$(curl -sSk -u "$old_user:$old_pass" -m 8 -o /dev/null -w '%{http_code}' "https://$ip/api/state" 2>/dev/null)
    [ "$scode" = "200" ] && ok "the dashboard login minted by the old version still authenticates after the update" ||
        bad "the old version's dashboard login no longer authenticates after the update (got HTTP $scode)"
}
