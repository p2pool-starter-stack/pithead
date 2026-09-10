# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_phase_provision_reboot() {
    # ---- reboot leg: the provisioned stack must return UNAIDED ---------------------------
    # pithead-boot owns recovery (#792): render the derived layer, compose up, health-gated slot commit.
    # Nothing may drive it here: no pithead command, no wizard. The failure mode this guards is a mining
    # appliance that sits dark after every power blip until a human logs in. The Caddyfile is corrupted FIRST
    # (#790): derived files are regenerated on every boot by construction, so a stale or broken one must not
    # survive — this is the defect that shipped new code against a days-old Caddyfile on hardware and killed
    # TLS.
    info "reboot leg — the stack must come back on its own (pithead-boot)"
    _ssh "echo '# corrupted by the harness — a regenerated boot must not serve this' > /data/pithead/Caddyfile" 2>/dev/null ||
        bad "could not corrupt the Caddyfile before the reboot"
    # And drop the baked-archive digest records: the wizard wrote them at first boot, so their
    # mere presence afterwards proves nothing. Gone, they must come back — that is
    # pithead-boot's own loader running on a provisioned machine (#798).
    _ssh "rm -f /data/pithead/data/.loaded-*.sha" 2>/dev/null ||
        bad "could not drop the digest records before the reboot"
    _reboot_wait reboot 300 || {
        bad "guest never returned from the reboot"
        return 1
    }
    local deadline2=$(($(date +%s) + 420)) names2=""
    while [ "$(date +%s)" -lt "$deadline2" ]; do
        names2=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names2" in
        *dashboard*caddy* | *caddy*dashboard*) break ;;
        esac
        sleep 10
    done
    case "$names2" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "stack returned after reboot with no hands on it (podman: $names2)"
        ;;
    *)
        bad "stack did NOT return after a reboot — running: '${names2:-none}'"
        return 1
        ;;
    esac
    tries=0
    local answered=0
    while [ "$tries" -lt 36 ]; do
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
        case "$code" in
        2?? | 3?? | 401 | 403)
            ok "dashboard answers again after the reboot (HTTP $code) — through a REGENERATED Caddyfile"
            answered=1
            break
            ;;
        esac
        sleep 5
        tries=$((tries + 1))
    done
    [ "$answered" -eq 1 ] || {
        bad "dashboard never answered after the reboot (last: $code)"
        return 1
    }
    assert_appliance_hostname_identity fixture-next "unaided reboot" "$pv_user" "$pv_pass"
    # No unit may be quietly broken (#792 sat visible in --failed for two RCs, unasserted).
    local failed_units
    # Transient healthcheck ephemera excluded: podman drives container healthchecks through
    # hash-named systemd-run units, and one dies harmlessly whenever compose recreates its
    # container mid-check. Every REAL unit (pithead-boot, tor, podman…) stays load-bearing.
    failed_units=$(_ssh "systemctl --failed --no-legend --no-pager --plain" 2>/dev/null |
        awk '$1 !~ /^[0-9a-f]{64}-[0-9a-f]+\.service$/' | tr -s ' ' | tr '\n' ';')
    if [ -z "${failed_units//[; ]/}" ]; then
        ok "no failed systemd units after the reboot"
    else
        bad "failed units after the reboot: $failed_units"
    fi
    # The records dropped before the reboot must be BACK: on a provisioned machine only
    # pithead-boot can have rewritten them, so this is the boot path running the baked-image
    # loader — the mechanism a keep-reinstall or A/B update depends on (#798).
    if _ssh "test -s /data/pithead/data/.loaded-dashboard.tar.gz.sha"; then
        ok "pithead-boot ran the baked-image loader (digest record rewritten)"
    else
        bad "the digest record never came back — pithead-boot did not run the loader"
    fi
    # Hugepages sizing on supported RAM (#977): the sizing unit runs every boot before the
    # stack, and on this 16 GiB guest it must be a NO-OP — the full 3072-page (6 GiB) pool
    # intact and no degraded marker. A short pool here means the sizing shrank supported
    # hardware; a marker means it cried wolf. The degrade tiers themselves are tier-1 (stack
    # suite, meminfo fixtures) — a second low-RAM VM would re-prove arithmetic.
    local hp_prov
    hp_prov=$(_ssh "awk '/^HugePages_Total/{print \$2}' /proc/meminfo" 2>/dev/null) || hp_prov=""
    if [ -n "$hp_prov" ] && [ "$hp_prov" -ge 3072 ]; then
        ok "full hugepage pool intact on a provisioned boot ($hp_prov pages — sizing left supported RAM alone)"
    else
        bad "hugepage pool short on a provisioned boot (HugePages_Total: ${hp_prov:-unreadable}, want >= 3072) — the sizing unit degraded a supported machine"
    fi
    if _ssh "systemctl is-active --quiet pithead-hugepages.service"; then
        ok "hugepages sizing unit ran this boot"
    else
        bad "hugepages sizing unit did not run — a low-RAM machine would get the silent 6 GiB carve-out"
    fi
    if _ssh "test ! -f /run/pithead-hugepages-degraded"; then
        ok "no degraded-hugepages marker on a supported machine"
    else
        bad "degraded-hugepages marker present on the 16 GiB guest: $(_ssh 'cat /run/pithead-hugepages-degraded' 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
    fi
    # The booted slot must commit ITSELF once healthy (#793) — no harness mark-good here. On a
    # real appliance nothing ever ran mark-good, so RAUC called both slots bad and every boot
    # took GRUB's degraded fallback path. A_OK=1 + A_TRY=0 is the committed state.
    local genv tries3=0
    while [ "$tries3" -lt 18 ]; do
        genv=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv" in
        *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*) break ;;
        esac
        sleep 10
        tries3=$((tries3 + 1))
    done
    case "$genv" in
    *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*)
        ok "booted slot committed itself after the health gate (A_OK=1 A_TRY=0)"
        ;;
    *)
        bad "slot never self-committed — grubenv: ${genv:-unreadable}"
        ;;
    esac
    # The miner must return too (#796): its unit lives in /run and died with the reboot, so
    # only pithead-boot's local-miner leg — which runs after the slot commit above — can have
    # brought it back. The cached build makes this a re-render, not a recompile.
    local mtries2=0 miner_back=0
    while [ "$mtries2" -lt 24 ]; do
        if _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null"; then
            miner_back=1
            break
        fi
        sleep 10
        mtries2=$((mtries2 + 1))
    done
    if [ "$miner_back" -eq 1 ]; then
        ok "built-in miner returned after the reboot (boot path re-ran its setup)"
    else
        bad "the miner did not return after the reboot — its runtime unit was never re-rendered"
    fi

    # ---- commit-gate honesty (#852): the gate must REFUSE a mining-dead slot ----------------
    # The slot self-committed above off a HEALTHY stack. But "the dashboard answers" is a subset of "the stack
    # is alive": a slot whose monerod/p2pool crashed while caddy+dashboard keep serving is exactly the
    # healthy-looking-but-dead slot a curl-only gate committed. The real gate is `pithead doctor --json`
    # (os/overlay/pithead-boot); assert its DECISION both ways on this running stack. Reboot/fallback can't
    # show it here — RAUC's commit is sticky, so the already-committed slot won't re-arm — so we drive the
    # gate command the boot path runs and check its exit code. This is the assertion whose absence let the
    # curl-only gate ship green.
    _gate() { _ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json >/dev/null 2>&1"; }
    # Healthy, mid initial sync with mining held (#35): the gate must COMMIT. A gate that rejected
    # this would never commit a fresh box — the over-tightening the sync-tolerant rule guards.
    if _gate; then
        ok "commit gate PASSES on the healthy stack (dashboard serving, node up, mining held for sync)"
    else
        bad "commit gate rejected a healthy still-syncing stack — a fresh box would never commit (over-tightened)"
    fi
    # Crash a revenue service: stop monerod. It stays down (restart:unless-stopped won't revive a
    # manual stop), so podman reports it exited — a chain node down. The gate must now REFUSE, so
    # pithead-boot would leave the slot uncommitted and A/B fallback would revert. A curl-only gate
    # PASSES here (the dashboard still answers) — that is the regression this leg catches.
    _ssh "podman stop -t 5 monerod >/dev/null 2>&1" || true
    if _gate; then
        bad "commit gate PASSED with monerod stopped — a mining-dead slot would self-commit (the curl-only gap)"
    else
        ok "commit gate REFUSES a slot whose monerod is down — left uncommitted, A/B fallback stays armed"
    fi
    phase_provision_failed_doctor_regression "$pv_user" "$pv_pass"
    _ssh "podman start monerod >/dev/null 2>&1" || true
    unset -f _gate

}
