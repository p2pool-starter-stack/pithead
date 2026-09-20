# shellcheck shell=bash
# shellcheck disable=SC2154  # ip/VM/DISK/SERIAL/token/jar/card_tok are run.sh's / phase_rig's
#
# #2063: the KVM battery has never once proven an ACCEPTED share on the appliance channel. The
# `rig` phase's own pool is the guest's own sshd (deliberately, #796) and the coordinator's
# built-in miner sits behind the sync gate forever on a scratch disk (#35) — so nothing upstream of
# "the miner unit is active" is proven there. #2062 (the `stack` phase) gives this leg its
# precondition for free: a coordinator guest provisioned in remote-node mode against the bench's
# ALREADY-SYNCED node clears the sync gate in minutes, not never, and can actually mine.
#
# Sourced by tests/os/run.sh and run inside phase_rig, at the point the rig sits committed, mining,
# on the updated slot — the same state rig_setup_again_coordinator_leg (the phase's last leg) is
# about to replace. Reuses that leg's own vocabulary (_setup_again_boot / _setup_again_session /
# _setup_again_rig_submit, tests/os/setup-again-leg.sh) to re-point the ALREADY-PROVEN rig at a
# second, concurrent guest instead of building a parallel rig lifecycle from scratch.
#
# The coordinator is a SECOND, concurrent libvirt guest, booted from the SAME image phase_rig
# already built for the rig (no second image build) — its own name/disk/serial, so it does not
# disturb the rig's. run.sh's globals ($VM/$DISK/$SERIAL/$ip) are swapped to the coordinator's
# identity only for the span of _provision_remote_node_coordinator (tests/os/phases/stack.sh, the
# #2062 helper this reuses rather than re-deriving), then restored before anything here touches the
# rig again — a single-threaded battery script, so the swap is safe exactly as long as nothing
# reads the globals mid-swap, which nothing here does.

# How long to wait for BOTH the rig's and the coordinator's own accepted counters to move off zero,
# once the rig is mining at the coordinator. p2pool's per-worker stratum difficulty is sized so a
# share should land in minutes on real hardware; a 4-vCPU guest with no hugepages and no MSR tuning
# is slower — inferred, not measured (the issue's own words). PITHEAD_OS_RIG_SHARE_WINDOW_SEC
# overrides this once a bench run has actually measured the guest's real time-to-first-share
# (`--keep`, per the issue's "measure first" ask); until then this is the conservative default, not
# a proven number.
RIG_SHARE_WINDOW_SEC="${PITHEAD_OS_RIG_SHARE_WINDOW_SEC:-1800}"

# Destroy the coordinator guest by name, independent of whatever the global $VM/$DISK/$SERIAL
# currently point at — called on every exit path below, success or failure, so a red leg never
# leaks a second guest into the next run's require_clean_bench (tests/os/lib/core.sh).
_rig_share_coord_teardown() { # <coord-vm> <coord-disk> <coord-serial>
    virsh destroy "$1" >/dev/null 2>&1 || true
    virsh undefine "$1" --nvram >/dev/null 2>&1 || true
    rm -f "$2" "$3"
}

# Bail out of rig_share_leg: report $1 (when given), tear down the coordinator guest and return 1.
# Reads coord_vm/coord_disk/coord_serial off the CALLER's frame (bash dynamic scoping — same trick
# _setup_again_session already relies on for `token`/`jar` below), so every early-return site here
# collapses to one line instead of repeating the teardown call.
_rig_share_abort() {
    [ -z "${1:-}" ] || bad "$1"
    _rig_share_coord_teardown "$coord_vm" "$coord_disk" "$coord_serial"
    return 1
}

# True when $1 (default 0 on empty/unset) is a positive integer — the shared shape of the four
# accepted-counter checks below, none of which can trust jq to have produced a clean number.
_gt0() { [ "${1:-0}" -gt 0 ] 2>/dev/null; }

# $1 already-built image (the rig's own v1), $2-$8 the remote-node inputs phase_rig read off the
# env (mh rpc zmq mu mp th grpc), $9 the rig's own ip (so it can be restored — the coordinator boot
# below overwrites the global $ip).
rig_share_leg() { # <image> <mh> <rpc> <zmq> <mu> <mp> <th> <grpc> <rig-ip>
    local img="$1" mh="$2" rpc="$3" zmq="$4" mu="$5" mp="$6" th="$7" grpc="$8" rig_ip="$9"
    local rig_vm="$VM" rig_disk="$DISK" rig_serial="$SERIAL"
    local coord_vm="${rig_vm}-coord" coord_disk="${rig_disk%.img}-coord.img" coord_serial="${rig_serial%.log}-coord.log"

    info "share leg (#2063) — the rig mines against a coordinator this battery itself boots, not its own sshd"
    # kvm_preflight's default 20480 MiB bar (#1059) is sized for ONE more 16 GiB guest, which is
    # exactly what's being booted here — the rig guest is ALREADY running at this point, so the
    # live MemAvailable reading already nets its usage out. Doubling the bar (job 719, #2063: host
    # MemAvailable=31089 MiB with the rig guest already up, comfortably enough for a second 16 GiB
    # guest) double-counted memory the rig guest already holds and refused a boot the host could
    # in fact back.
    kvm_preflight || return 1

    VM="$coord_vm" DISK="$coord_disk" SERIAL="$coord_serial" ip=""
    local coord_ok=0 coord_ip="" coord_user="" coord_pass=""
    if _provision_remote_node_coordinator "$img" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc"; then
        coord_ok=1
        coord_ip="$ip"
        coord_user="$dash_user"
        coord_pass="$dash_pass"
    fi
    VM="$rig_vm" DISK="$rig_disk" SERIAL="$rig_serial" ip="$rig_ip"
    [ "$coord_ok" = 1 ] || _rig_share_abort "share leg: the coordinator guest never released — cannot prove a share against it" || return 1
    ok "share leg: coordinator released at $coord_ip, on the same libvirt network as the rig"

    # Re-point the ALREADY-PROVEN rig at the coordinator's stratum, through the same "Set up again"
    # menu entry rig_setup_again_legs already exercised (tests/os/setup-again-leg.sh) — never a
    # second from-scratch rig lifecycle. Still role=rig; the worker name is new so its accepted
    # counter is unambiguously zero at the start of this leg, not a stale carry from 127.0.0.1:22.
    # shellcheck disable=SC2034  # local on purpose: shadows phase_rig's OWN `token`, so
    # _setup_again_session's dynamically-scoped write below lands here, not in the caller's frame
    local jar="" token="" new_card=""
    _setup_again_boot 300 || _rig_share_abort || return 1
    _setup_again_session || _rig_share_abort || return 1
    new_card=$(_setup_again_rig_submit kvm-rig-share "$coord_ip:3333") || {
        rm -f "$jar"
        _rig_share_abort || return 1
    }
    rm -f "$jar"
    [ -n "${new_card%% *}" ] && ok "share leg: the rig re-provisioned against $coord_ip:3333" ||
        bad "share leg: no card token came back from the re-provisioned rig"

    _rig_mining_up 36 && ok "share leg: the rig mines again, now at the coordinator" ||
        _rig_share_abort "share leg: the rig never resumed mining against the coordinator" || return 1
    if _ssh "jq -e '.pools[0].url == \"$coord_ip:3333\"' /data/rigforge/config.json >/dev/null"; then
        ok "share leg: the rig's miner config points at the coordinator, not its own sshd"
    else
        bad "share leg: the rig's miner config does not name the coordinator ($(_ssh "jq -c '.pools' /data/rigforge/config.json 2>/dev/null" | cut -c1-100))"
    fi

    # The assertion of this whole issue: BOTH sides of the coordinator's own /api/state must show
    # an accepted count that moved off zero — the rig's worker (proves the OTHER machine this image
    # installs can mine into a real p2pool) and at least one OTHER worker (the coordinator's own
    # built-in miner, left enabled at its wizard default — proves the coordinator side too, since
    # the appliance channel has never had a built-in miner clear the sync gate before either).
    local deadline=$(($(date +%s) + RIG_SHARE_WINDOW_SEC)) st="" rig_accepted=0 other_accepted=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        st=$(curl -sSk -u "$coord_user:$coord_pass" -m 10 "https://$coord_ip/api/state" 2>/dev/null)
        rig_accepted=$(printf '%s' "$st" | jq -r '[.workers[]? | select(.name == "kvm-rig-share") | .accepted // 0] | add // 0' 2>/dev/null)
        other_accepted=$(printf '%s' "$st" | jq -r '[.workers[]? | select(.name != "kvm-rig-share") | .accepted // 0] | add // 0' 2>/dev/null)
        _gt0 "$rig_accepted" && _gt0 "$other_accepted" && break
        sleep 15
    done
    if _gt0 "$rig_accepted"; then
        ok "share leg: the rig's worker shows accepted=$rig_accepted on the coordinator it mines at"
    else
        bad "share leg: the rig's worker never showed an accepted share within ${RIG_SHARE_WINDOW_SEC}s (workers: $(printf '%s' "$st" | jq -c '.workers' 2>/dev/null))"
    fi
    if _gt0 "$other_accepted"; then
        ok "share leg: the coordinator's own built-in miner shows accepted=$other_accepted too — the appliance channel's first live proof past the sync gate"
    else
        bad "share leg: the coordinator's own built-in miner never showed an accepted share within ${RIG_SHARE_WINDOW_SEC}s"
    fi

    _rig_share_coord_teardown "$coord_vm" "$coord_disk" "$coord_serial"
}
