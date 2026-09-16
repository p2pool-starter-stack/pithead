# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# M10 (#2067a): every power cut the battery had injected landed on a bare guest (fault.sh) or a
# clean reboot (provision-reboot.sh) — never a cut while a PROVISIONED stack was actually live.
# This mirrors fault.sh's Fault A (destroy, sleep, start, three times — "repeat three times, as M8
# does") against the stack _phase_provision_reboot just proved comes back on its own, then asserts
# the M10-specific facts a plain reboot cannot: the chain height did not go backwards, the image
# store survived (the #1029 class), the miner and the boot-gated commit are both still there.
#
# #2067 allows a held (still-syncing) stack for a first version rather than the full remote-node
# repoint M10 describes on real hardware — a KVM guest never clears the sync gate (#2063), so a
# "resumed mining" assertion has nothing to observe here regardless of node mode. What IS provable
# without a synced chain is that the height recorded before the cut never regresses, which is the
# property M10 actually guards against (a slot that forgot how far it had gotten).
_phase_provision_power_cut() {
    info "power-cut leg (M10) — cut power while the provisioned stack is live, three times"
    local i height_before names_before names images_before images slot_before slot_after before
    # monerod's RPC can still be starting even once the provision phase has otherwise settled, so a
    # single-shot read here raced it the same way the post-cut read once did (see below). Poll it
    # the same way rather than failing the whole leg on a transient "not answering yet".
    local htries_before=0
    while [ "$htries_before" -lt 18 ]; do
        height_before=$(_monerod_height)
        [ -n "$height_before" ] && break
        sleep 10
        htries_before=$((htries_before + 1))
    done
    names_before=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
    images_before=$(_ssh "podman images --format '{{.Repository}}:{{.Tag}}@{{.Digest}}'" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
    slot_before=$(_ssh "grub-editenv /boot/efi/grub/grubenv list 2>/dev/null | grep -E '^(A_OK|A_TRY)=' | LC_ALL=C sort" | tr '\n' ' ')
    [ -n "$names_before" ] && [ -n "$images_before" ] && [ -n "$slot_before" ] || {
        bad "could not record the live stack, stored-image, and slot baseline before the power cuts"
        return 1
    }
    for i in 1 2 3; do
        before=$(_boot_id) || {
            bad "M10.$i: could not read the boot id before the power cut"
            return 1
        }
        virsh destroy "$VM" >/dev/null 2>&1 || {
            bad "M10.$i: could not cut power"
            return 1
        }
        sleep 3
        virsh start "$VM" >/dev/null 2>&1 || {
            bad "M10.$i: could not restore power"
            return 1
        }
        if ! _wait_new_boot "$before" 300; then
            bad "M10.$i: BRICKED — no boot after a power cut with the stack live (disqualifying)"
            return 1
        fi
        local deadline=$(($(date +%s) + 420))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
            [ "$names" = "$names_before" ] && break
            sleep 10
        done
        [ "$names" = "$names_before" ] &&
            ok "M10.$i: every pre-cut container returned before the next cut ($names)" || {
            bad "M10.$i: the stack did NOT return before the next cut (wanted: '$names_before'; running: '${names:-none}')"
            return 1
        }
    done

    # The #1029 class, from a REAL virsh destroy rather than the unit-tested fixture: an
    # interrupted image load can leave containers/storage holding zero-length `lower` files, which
    # is the exact signal lib/pithead/11-baked-images.sh's own repair_broken_image_store looks for
    # (and, once found, rebuilds). Asking the store the same question it asks itself is cheaper and
    # more honest than starting every stored container to find out.
    local broken
    broken=$(_ssh 'root=$(podman info --format "{{.Store.GraphRoot}}" 2>/dev/null); find "$root/overlay" -maxdepth 2 -name lower -size 0 -print -quit 2>/dev/null')
    if [ -z "$broken" ]; then
        ok "the image store is runnable — no zero-length layer metadata after the power cuts"
    else
        bad "the image store is damaged after the power cuts: $broken"
    fi
    images=$(_ssh "podman images --format '{{.Repository}}:{{.Tag}}@{{.Digest}}'" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
    if [ "$images" = "$images_before" ]; then
        ok "every stored image still has its pre-cut digest after the power cuts"
    else
        bad "stored image digests changed after the power cuts (wanted: '$images_before'; got: '${images:-unreadable}')"
    fi

    if [ -n "$height_before" ]; then
        # monerod's own container can still be starting up the instant the earlier checks above
        # pass (they ask podman and curl, not the chain RPC), so a single-shot read here raced it
        # and misread "not answering yet" as "went backwards". Poll the same way the pre-cut read,
        # the miner, and the dashboard checks do.
        local height_after="" htries=0
        while [ "$htries" -lt 18 ]; do
            height_after=$(_monerod_height)
            [ -n "$height_after" ] && break
            sleep 10
            htries=$((htries + 1))
        done
        if [ -n "$height_after" ] && [ "$height_after" -ge "$height_before" ] 2>/dev/null; then
            ok "monerod reports height $height_after, at or past the pre-cut height $height_before"
        else
            bad "monerod height went backwards or is unreadable (before: $height_before, after: ${height_after:-unreadable})"
        fi
    else
        bad "could not read monerod's height before the power cuts — the M10 height guarantee was not exercised"
    fi

    local mtries=0 miner_back=0
    while [ "$mtries" -lt 24 ]; do
        _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null" && {
            miner_back=1
            break
        }
        sleep 10
        mtries=$((mtries + 1))
    done
    [ "$miner_back" -eq 1 ] && ok "the miner unit is active after the power cuts" ||
        bad "the miner did not return after the power cuts"

    local tries=0 code=000 answered=0
    while [ "$tries" -lt 36 ]; do
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
        case "$code" in 2?? | 3?? | 401 | 403)
            answered=1
            break
            ;;
        esac
        sleep 5
        tries=$((tries + 1))
    done
    [ "$answered" -eq 1 ] && ok "the dashboard answers through caddy after the power cuts (HTTP $code)" ||
        bad "the dashboard never answered through caddy after the power cuts (last: $code)"

    # The slot must still self-commit — a power cut mid-write must not leave it perpetually
    # uncommitted (every future boot would take GRUB's fallback path forever).
    local genv tries3=0
    while [ "$tries3" -lt 18 ]; do
        genv=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv" in *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*) break ;; esac
        sleep 10
        tries3=$((tries3 + 1))
    done
    case "$genv" in
    *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*)
        slot_after=$(printf '%s\n' "$genv" | tr ' ' '\n' | grep -E '^(A_OK|A_TRY)=' | LC_ALL=C sort | tr '\n' ' ')
        [ "$slot_after" = "$slot_before" ] &&
            ok "the slot stayed committed after the power cuts — pithead-boot committed nothing new" ||
            bad "the slot commit state changed after the power cuts (before: '$slot_before'; after: '$slot_after')"
        ;;
    *) bad "the slot is not committed after the power cuts — grubenv: ${genv:-unreadable}" ;;
    esac
}

# monerod's RPC, read the same way soak-probe.sh does: node credentials from /data/pithead/.env,
# a restricted get_info if none are set.
_monerod_height() {
    _ssh 'env_get() { sed -n "s/^$1=//p" /data/pithead/.env 2>/dev/null | head -1 | tr -d "\""; }
mu=$(env_get MONERO_NODE_USERNAME); mp=$(env_get MONERO_NODE_PASSWORD); murl=$(env_get MONERO_RPC_URL); [ -n "$murl" ] || murl=http://127.0.0.1:18081
if [ -n "$mu" ]; then curl -fsS --max-time 8 --digest -u "$mu:$mp" "$murl/get_info" 2>/dev/null; else curl -fsS --max-time 8 "$murl/get_info" 2>/dev/null; fi' |
        jq -r '.height // empty' 2>/dev/null
}
