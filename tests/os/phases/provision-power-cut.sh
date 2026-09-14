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
    local i height_before
    height_before=$(_monerod_height)
    for i in 1 2 3; do
        virsh destroy "$VM" >/dev/null 2>&1 || true
        sleep 3
        virsh start "$VM" >/dev/null 2>&1 || true
        if _wait_ssh 300; then
            ok "M10.$i: survived a power cut with the stack live — booted"
        else
            bad "M10.$i: BRICKED — no boot after a power cut with the stack live (disqualifying)"
            return 1
        fi
    done

    local names deadline=$(($(date +%s) + 420))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 10
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ok "every container returned after the power cuts (podman: $names)" ;;
    *) bad "the stack did NOT return after the power cuts — running: '${names:-none}'" ;;
    esac

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
    if _ssh "podman images >/dev/null 2>&1"; then
        ok "podman images still runs after the power cuts"
    else
        bad "podman images failed after the power cuts"
    fi

    if [ -n "$height_before" ]; then
        local height_after
        height_after=$(_monerod_height)
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
        ok "the slot is still committed after the power cuts (A_OK=1 A_TRY=0) — pithead-boot committed nothing new"
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
