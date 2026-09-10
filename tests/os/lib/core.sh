# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n' "$1"
}
info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
KEY="$HOME/.ssh/pithead-os-test"
ip=""
# Overwritten by every _ssh call with that call's stderr (empty on success). Not a log — just the
# LAST attempt's error text, so a caller that just gave up can classify why without another round
# trip. See _ssh_unreachable_reason.
SSH_ERR="/tmp/pithead-os-ssh.err"
# A fresh run must not inherit the last run's preserved console: the cleanup copy below is
# no-clobber (the at-assertion copy is the authoritative one), so clear the slate here.
rm -f "$SERIAL.failed"
# The wallet every phase submits. It must be checksum-VALID: p2pool refuses a well-formed but
# checksum-invalid address at startup with a SIGABRT and crash-loops (#829), which killed the
# provision phase's whole miner chain when the harness used `4` + 94×`A`. Host-side validation
# only checks the shape, so the crash is the first honest verdict. XMRig's public donation
# address: obviously not ours, plainly labelled, and any share it ever earned would be a donation.
# shellcheck disable=SC2034  # shared through the assembled runner scope
HARNESS_WALLET="44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg"
# A real base58 Tari address: the wizard now decodes + checksum-validates it host-side, so a
# made-up placeholder is (correctly) rejected before the flow ever reaches the credentials
# handoff. Same throwaway address the stack suite uses.
# shellcheck disable=SC2034  # shared through the assembled runner scope
HARNESS_TARI="126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ"

# Every remote call is bounded. CORRECTION (this comment used to claim Debian socket-activates sshd —
# disproven): os/rootfs/Dockerfile only ever `systemctl enable`/`disable`s the plain ssh.service; no
# ssh.socket unit is ever enabled. What actually gates it is os/overlay/pithead-ssh-host-keys.conf, a drop-in
# that adds RequiresMountsFor=/data plus an ExecStartPre chain (generate the host key onto /data, then `sshd
# -t`) — so ssh.service cannot even begin starting until data.mount is active, and /data is freshly mkfs'd and
# grown by systemd-repart (os/rootfs/repart.d/40-data.conf) on every first boot. A guest whose sshd has not
# started yet therefore just refuses the connection (nothing is listening); it does not stall the handshake.
# The five-hour stall this bound exists for (2026-08-15: one boot-phase probe held for five hours against a
# guest that answered ssh normally the whole time, and the phase reported "SSH never came up" the instant that
# probe was killed) was an unbounded remote call outliving its own caller's deadline, not sshd's start order —
# bounding every call here is what fixed it, regardless of which cause produces the next stall. SSH_TIMEOUT is
# the per-call ceiling. The default is deliberately far larger than any legitimate call (the longest here is
# the 1800 s local-miner wait; a slot copy on slow storage is the other long one): this exists ONLY to stop an
# infinite hang, so it must never be the thing that ends real work — if a call is legitimately slower than
# this, raise it rather than let the ceiling arbitrate. ponytail: polling loops lower it to a few seconds — a
# stalled handshake must read as "not ready yet" so the loop re-evaluates its own deadline, which is the whole
# point of having one.
_ssh() {
    timeout "${SSH_TIMEOUT:-5400}" ssh -i "$KEY" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "root@$ip" "$@" 2>"$SSH_ERR"
}
_wait_ssh() { # $1 seconds — the definition of "not bricked"
    local deadline=$(($(date +%s) + $1)) SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        _ssh true && return 0
        sleep 5
    done
    return 1
}
_boot_id() { _ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n' | grep .; } # rc 1 when unreadable
# A reboot is OBSERVED, never assumed (#1651): wait for a boot id DIFFERENT from $1. `sleep 10; _wait_ssh` reconnected
# to the still-running old boot whenever the shutdown outlasted the sleep (or the reboot command never landed) and
# read the OLD marker as the verdict. Reports how many probes the old boot answered, so a near-miss is visible.
_wait_new_boot() { # $1 = boot id before the reboot, $2 = seconds
    local deadline=$(($(date +%s) + $2)) SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" now='' stale=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        now=$(_boot_id)
        [ -n "$now" ] && [ "$now" != "$1" ] && break
        [ "$now" = "$1" ] && stale=$((stale + 1))
        sleep 5
    done
    [ "$stale" -eq 0 ] || info "the old boot $1 answered $stale probe(s) after the reboot command before going down"
    [ -n "$now" ] && [ "$now" != "$1" ] && return 0
    info "no new boot within $2 s — boot id ${now:-unreadable}, was $1"
    return 1
}
_reboot_wait() { # $1 = the command that reboots the guest, $2 = seconds to wait for the new boot
    local before
    before=$(_boot_id) || info "could not read the boot id before '$1' — a reconnect and a reboot would look alike"
    [ -n "$before" ] || return 1
    _ssh "$1" >/dev/null 2>&1 || true # the session dies with the reboot
    _wait_new_boot "$before" "$2"
}
# Classify why _wait_ssh gave up, using only signals that do NOT need a working SSH session — the
# guest either isn't running, isn't the one we're still probing, or is running and refusing the
# connection (sshd not up yet, or genuinely dead) vs. not answering the network at all. $1 is the
# ip that was being probed.
_ssh_unreachable_reason() {
    local probed_ip="$1" state cur_ip
    state=$(virsh domstate "$VM" 2>/dev/null || echo unknown)
    if [ "$state" != "running" ]; then
        printf 'guest VM is not running (libvirt state: %s) — it never had a chance to answer SSH' "$state"
        return
    fi
    cur_ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "$cur_ip" ] && [ "$cur_ip" != "$probed_ip" ]; then
        printf 'guest now holds a DIFFERENT DHCP lease (%s, was probing %s) — it rebooted mid-boot and the probe was aimed at a dead lease, not a dead sshd' "$cur_ip" "$probed_ip"
        return
    fi
    if grep -qi refused "$SSH_ERR" 2>/dev/null; then
        printf 'guest answers on the network but refuses port 22 — sshd is still gated behind the /data mount + host-key generation (pithead-ssh-host-keys.conf), or failed to start; not a network problem'
        return
    fi
    # An auth rejection is the single most diagnostic answer here and it used to fall through to
    # the catch-all below, which reported a BENCH KEY MISMATCH as "guest never answered the
    # network — DHCP/routing/firewall problem". That is the opposite of what happened: sshd was up,
    # reachable, and said no. The misreport sent several sessions hunting product-side boot theories
    # (socket activation, RequiresMountsFor=/data) for a harness misconfiguration, so the classifier
    # names it explicitly and says which key it offered.
    if grep -qiE 'permission denied|no supported authentication|too many authentication' "$SSH_ERR" 2>/dev/null; then
        printf 'guest sshd is UP and REJECTED our key (%s) — this is authentication, not boot and not networking. The image bakes the pubkey passed to os/build-image.sh --ssh; if that is not the counterpart of the key this harness probes with, every phase that needs SSH fails like a dead guest' "$KEY"
        return
    fi
    printf 'guest never answered the network at all (last ssh error: %s) — DHCP/routing/firewall problem, not an sshd problem' "$(tr -s ' \n' ' ' <"$SSH_ERR" 2>/dev/null || echo none)"
}
_marker() { _ssh cat /etc/pithead-test-marker 2>/dev/null | tr -d "\r\n"; }

# The marker baked INTO the dashboard image and served by whatever container actually answers
# (/static/os-test-marker.txt, stamped by os/build-image.sh on harness builds). Distinct from
# /etc/pithead-test-marker, which only names the OS slot: the image tag is identical across
# builds, so this is the one signal that separates "new OS, new containers" from the #798
# failure — new OS, stale containers, every other check green. $1 expected, $2 seconds.
_dash_marker_served() {
    local want="$1" deadline=$(($(date +%s) + ${2:-300})) got=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        got=$(curl -fsSk -m 5 "https://$ip/static/os-test-marker.txt" 2>/dev/null)
        [ "$got" = "$want" ] && return 0
        sleep 5
    done
    printf '%s' "${got:-nothing}"
    return 1
}

# Poll until the guest has taken a DHCP lease. No guest agent in the appliance image (by
# design), so the lease is the source of truth. Sets the global `ip`. $1 seconds.
_wait_dhcp_ip() {
    local deadline=$(($(date +%s) + $1))
    ip=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] && return 0
        sleep 3
    done
    return 1
}

# Poll until the setup wizard's gate page answers on the global `ip`. The console announcement
# fires when the wizard CONTAINER starts, not when the Python server inside has bound its
# sockets, so the gate answers a little after the token prints — same retry shape everywhere
# this file waits on it. $1 seconds.
_wait_setup_page() {
    local deadline=$(($(date +%s) + $1))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        curl -fsSk -m 5 "https://$ip/" 2>/dev/null | grep -qi "Pithead setup" && return 0
        sleep 5
    done
    return 1
}

# Build a bootable image carrying $1 as its slot marker, for the selected updater.
_build_image() {
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -f "$KEY" -q
    # What this harness believes it is building, so verify-image's stale-artifact guard runs here
    # too. It used to be unset in the only automated caller, which left the check that exists
    # BECAUSE an image shipped a two-commits-stale dashboard switched off in every battery run
    # (#1064). build-image.sh stamps the FULL sha, so that is the shape to hand over: a short one
    # never matched, and wiring the guard on with it would have failed every build the harness made.
    local expect
    expect="$(git rev-parse HEAD 2>/dev/null || true)"
    # PITHEAD_REGISTRY/_CA are forwarded rather than inherited-by-luck: the battery runs under
    # sudo, whose `env_reset` drops them, so the documented recipe has to be
    # `sudo env PITHEAD_REGISTRY=... tests/os/run.sh`. Without them build-image.sh refuses (#2043)
    # — and that refusal used to land ONLY in the log below, so the phase reported the useless
    # "image build failed" and the reason went unread. Surface it where the operator is looking.
    PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
    PITHEAD_REGISTRY="${PITHEAD_REGISTRY:-}" PITHEAD_REGISTRY_CA="${PITHEAD_REGISTRY_CA:-}" \
        os/build-image.sh >/tmp/os-fault-build.log 2>&1 || {
        tail -12 /tmp/os-fault-build.log >&2
        return 1
    }
    os/rauc/mkimage.sh --dev >>/tmp/os-fault-build.log 2>&1 || return 1
    # Every image a phase boots gets the static verification first, in --test mode. The check
    # that matters most is the archive-vs-tree comparison: stale wizard images reached three
    # benches through caching bugs, and this layer catches the next one before a 25-minute
    # phase runs against it.
    PITHEAD_EXPECT_COMMIT="$expect" tests/os/verify-image.sh os/rauc/build/system.img --test >>/tmp/os-fault-build.log 2>&1 || {
        echo "verify-image failed on the freshly built image (see /tmp/os-fault-build.log)" >&2
        return 1
    }
    printf 'os/rauc/build/system.img'
}

# Build an update bundle carrying $1 as its marker.
_build_bundle() {
    PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
        os/build-image.sh >/tmp/os-fault-bundle.log 2>&1 || return 1
    os/rauc/mkbundle.sh --dev >>/tmp/os-fault-bundle.log 2>&1 || return 1
    find os/rauc/build -name '*.raucb' | head -1
}

# Bundles are signed with the dev chain and RAUC verifies them against the keyring baked into the
# slot, so nothing but the bundle itself needs staging.
_stage_bundle() { # $1 bundle path
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "$1" "root@$ip:/data/update.bundle"
}

# Per-updater command vocabulary — the ONLY updater-specific part of the battery.
#
# NOTE RAUC refuses unsigned bundles, which is correct — the battery signs with the development
# chain generated below and verification runs for real. Production signs with the release key; see
# the signing section of the plan.
_install_cmd() {
    printf 'rauc install %s' "$1"
}
_commit_cmd() {
    printf 'rauc status mark-good'
}
# Booting the newly written slot. RAUC arms the GRUB try-counter during install, so a plain
# reboot already lands on it.
_boot_spare_cmd() {
    printf 'reboot'
}
# The normal update path an operator would take: install and end up running the new version.
_install_and_boot_cmd() {
    printf 'rauc install %s && systemctl reboot' "$1"
}
# Operator-initiated rollback: the "put it back" button, distinct from automatic fallback.
_rollback_cmd() {
    printf 'rauc status mark-bad booted && reboot'
}

require_host() {
    # timeout bounds every remote call (see _ssh) — without it each one dies 127 and the whole
    # run reads as a bricked guest, so it is a hard dependency, not a nicety.
    for c in virsh virt-install qemu-img timeout; do
        have "$c" || {
            echo "missing $c — install libvirt/qemu (see tests/os/README.md)" >&2
            exit 2
        }
    done
    [ -e /dev/kvm ] || {
        echo "/dev/kvm absent — this harness needs hardware virtualization" >&2
        exit 2
    }
    # --image is the boot phase's input; update and fault build their own v1/v2 images.
    if [ "$PHASE" = "boot" ] || [ "$PHASE" = "all" ]; then
        [ -n "$IMAGE" ] && [ -f "$IMAGE" ] || {
            echo "--image PATH is required for the boot phase (build with os/build-image.sh)" >&2
            exit 2
        }
    fi
    require_probe_key_matches_image
}

# The harness probes the guest as root with $KEY; the image authorizes whatever pubkey was passed
# to `os/build-image.sh --ssh`. Nothing tied those together, and when they drifted apart — the
# driver built as an unprivileged user with that user's key while the harness ran under sudo with
# root's DIFFERENT key — the guest correctly refused every probe. That is indistinguishable from a
# dead guest once you are only watching a timeout, and it cost several sessions: three separate
# product-side theories were written up for what was a bench key mismatch, and the boot leg had in
# fact never once passed. Compare them here, before a multi-minute build and boot, and say so.
require_probe_key_matches_image() {
    [ -f "$KEY" ] || {
        echo "probe key $KEY not found — the harness authenticates to the guest with it" >&2
        exit 2
    }
    [ -n "$IMAGE" ] && [ -f "$IMAGE" ] || return 0
    local want
    # ssh-keygen -y derives the public half from the PRIVATE key, so this checks the actual keypair
    # rather than trusting a .pub file that may not be its counterpart — which is exactly how the
    # two drifted apart.
    want=$(ssh-keygen -y -f "$KEY" 2>/dev/null | awk '{print $1" "$2}')
    [ -n "$want" ] || return 0 # passphrase-protected or unreadable: not our call to judge here
    # Presence, not "the first key in the image": an image legitimately contains other keys (host
    # keys, fixtures), so comparing against whichever one appears first would refuse perfectly good
    # benches. If our pubkey is absent it cannot possibly authorize us, and that is the whole test.
    # A release image is shell-less and carries no authorized key at all, so only assert on debug
    # images — the only ones the harness can drive.
    grep -aq 'pithead-variant\|authorized_keys' "$IMAGE" 2>/dev/null || return 0
    grep -aqF "$want" "$IMAGE" 2>/dev/null || {
        echo "refusing to run: this image does not authorize the key the harness probes with." >&2
        echo "  harness key: $KEY" >&2
        echo "  its pubkey : $want" >&2
        echo "Every phase that needs SSH would fail like a dead guest — sshd answers and says no," >&2
        echo "which reads as a boot or network fault. Rebuild the image with" >&2
        echo "  os/build-image.sh --ssh $KEY.pub" >&2
        echo "or point \$KEY at the keypair the image was built with." >&2
        exit 2
    }
}

# A stray VM on the same libvirt network can take the DHCP lease the harness then reads back,
# so the battery silently drives someone else's guest. This happened with a hand-started
# diagnostic VM and produced passing legs that proved nothing. Refuse to run rather than report.
require_clean_bench() {
    local guests strays
    guests=$(virsh list --name 2>/dev/null) || {
        echo "refusing to run: libvirt could not enumerate the bench." >&2
        exit 2
    }
    strays=$(printf '%s\n' "$guests" | grep -E '^pithead-' | grep -v "^${VM}$" || true)
    [ -z "$strays" ] || {
        echo "refusing to run: other pithead VMs are on the bench and can steal the lease:" >&2
        echo "$strays" >&2
        echo "destroy them first (virsh destroy <name>; virsh undefine <name> --nvram)" >&2
        exit 2
    }
}
cleanup() {
    local approval_cleanup_rc=0
    declare -F approval_fixture_cleanup >/dev/null && approval_fixture_cleanup || approval_cleanup_rc=$?
    # Preserve the console on failure; an at-assertion no-clobber copy remains authoritative.
    if [ "$FAIL" -gt 0 ] && [ -s "$SERIAL" ] && [ ! -f "$SERIAL.failed" ]; then
        cp "$SERIAL" "$SERIAL.failed" 2>/dev/null &&
            info "console from the failed run kept at $SERIAL.failed"
    fi
    if [ "$KEEP" -eq 1 ]; then
        info "left VM '$VM' and $DISK in place (--keep)"
        [ "$approval_cleanup_rc" -eq 0 ] || exit "$approval_cleanup_rc"
        return
    fi
    vm_destroy && rm -f "$DISK" "$SERIAL" "$SSH_ERR" || approval_cleanup_rc=1
    [ "$approval_cleanup_rc" -eq 0 ] || exit "$approval_cleanup_rc"
}
trap cleanup EXIT
# Wait until the serial log matches a pattern, or time out. $1 pattern, $2 seconds.
wait_serial() {
    local pat="$1" deadline=$(($(date +%s) + ${2:-180}))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        grep -qE "$pat" "$SERIAL" 2>/dev/null && return 0
        sleep 3
    done
    return 1
}
