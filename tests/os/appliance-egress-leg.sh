#!/usr/bin/env bash
# Tor-only egress ENFORCEMENT backstop for the provisioned appliance (#855/#2059). Sourced by
# tests/os/run.sh; --self-test exercises the pure probe list without a guest.
#
# Why this lives in its own file rather than inline at the tail of the provision phase (#2059):
# it is the only tier-4 assertion in the repo that proves the KERNEL enforces Tor-only egress, and
# it used to sit ~55 lines from the end of `_phase_provision_initial`, downstream of a dozen
# `return 1` aborts on unrelated liveness legs (the image build, SSH, the wizard token, the
# credentials handoff, caddy answering on :443). Any red in any of those retired the product's
# stated security property SILENTLY while the battery still reported on everything it did reach —
# which is how a fail-open appliance shipped green through every battery to date. The caller now
# runs this on every path and it says out loud when it could not be exercised.
#
# Tier 1 (tests/stack/test-tor-network.sh) proves the RENDERED ruleset; tier 4 is the only tier
# that can show the kernel acting on it. There are two backends behind one allow-set
# (lib/pithead/02-tor-egress.sh): iptables/DOCKER-USER on the DIY Docker channel and an
# independent `inet pithead_egress` nftables table on the appliance's podman/netavark channel.
# The e2e channel runs Docker, so this leg is the netavark backend's only live coverage anywhere.

# Diagnostic probes run when an enforcement assertion FAILS. Pure (no I/O) so it self-tests, and
# single-sourced so the capture set cannot drift from what #2059 asked for.
#
# The leading question on a red is whether the nft table is ABSENT (the apply silently failed, or
# resolved no bridge) or PRESENT but INEFFECTIVE (wrong interface, or netavark's priority-0 accept
# winning anyway). Those need opposite fixes and the dial alone cannot tell them apart, so every
# future red would otherwise cost another KVM cycle to diagnose — the same gap #2054 closed for the
# restore leg. `engine` is the first row on purpose: apply_tor_egress_firewall branches on
# container_engine, and a `docker` verdict on the appliance sends the rules into the orphaned
# DOCKER-USER chain, which is failure mode #1 for this defect.
egress_diag_probes() { # -> "<label>\t<remote command>" per line
    printf '%s\t%s\n' \
        'engine' 'grep -h "^PITHEAD_ENGINE=" /etc/environment 2>/dev/null; cd /data/pithead 2>/dev/null && bash -c "source ./pithead && container_engine" 2>/dev/null' \
        'nft-table' 'nft list table inet pithead_egress 2>&1' \
        'nft-hook' 'nft list ruleset 2>/dev/null | grep -A20 pithead_egress' \
        'mining-net' 'podman network inspect mining_net 2>&1 | head -c 600' \
        'boot-log' 'journalctl -u pithead-boot --no-pager 2>/dev/null | grep -i egress | tail -5' \
        'firstboot-log' 'journalctl -u pithead-firstboot --no-pager 2>/dev/null | grep -i egress | tail -5'
}

# Run every probe and print a bounded one-line excerpt each. Bounded on purpose: the harness
# contract (CLAUDE.md) is that raw dumps never reach model context — this is a signpost telling the
# next run which half of the fork it is on, not the evidence itself. The full guest is still there
# under `--keep` for anyone who needs the untruncated ruleset.
_egress_capture_diagnostics() {
    local label cmd out
    info "  egress diagnostics (#2059) — is the table ABSENT, or PRESENT but ineffective?"
    while IFS=$'\t' read -r label cmd; do
        [ -n "$label" ] || continue
        out=$(_ssh "$cmd" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | cut -c1-220)
        info "    $label: ${out:-<empty>}"
    done < <(egress_diag_probes)
}

# The enforcement leg. Never returns non-zero in a way the caller acts on — it reports through
# ok/bad like every other assertion.
#
# <phase-rc> is the provision body's result so far. It decides only how an UNEXERCISED backstop is
# reported: on an already-red phase a "could not run" line is an `info` (the battery verdict is
# already FAIL, nothing is being hidden), but on a GREEN phase it is a `bad` — a passing battery
# must never quietly omit the product's stated security property. That asymmetry is the whole point
# of #2059.
phase_provision_egress_backstop() { # <phase-rc>
    local phase_rc="${1:-0}"
    local unexercised=bad
    [ "$phase_rc" -eq 0 ] || unexercised=info

    info "phase: Tor-only egress enforcement backstop (#855/#2059)"
    if ! SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh true 2>/dev/null; then
        "$unexercised" "guest is unreachable — the Tor-only egress backstop was NOT exercised (#855/#2059)"
        return 0
    fi

    # monerod sits on mining_net (172.28.0.x) and syncs regardless of the mining hold, so it is the
    # honest origin for the dial. Its baked archive is the largest and loads last — dashboard+caddy
    # answering does not mean monerod exists yet. A `podman exec` against a missing container fails
    # exactly like a missing curl binary, which used to blame the wrong thing (#887). Wait first.
    local monerod_deadline=$(($(date +%s) + 300)) monerod_present=0
    while [ "$(date +%s)" -lt "$monerod_deadline" ]; do
        case "$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null)" in
        *monerod*)
            monerod_present=1
            break
            ;;
        esac
        sleep 5
    done
    if [ "$monerod_present" -ne 1 ]; then
        "$unexercised" "monerod container never came up — cannot assert the Tor-only egress drop (the #855 backstop is unverified)"
        return 0
    fi
    if ! _ssh "podman exec monerod sh -c 'command -v curl' >/dev/null 2>&1"; then
        "$unexercised" "curl missing from the monerod image — cannot assert the Tor-only egress drop (the #855 backstop is unverified)"
        return 0
    fi

    # NEGATIVE — a direct clearnet dial by IP must be DROPPED (curl times out, non-zero). This is
    # the check whose absence let a leaking appliance ship green: it FAILS against the
    # orphaned-chain code and PASSES once the nft table is installed and effective.
    if _ssh "podman exec monerod curl -s -o /dev/null -m 8 http://1.1.1.1/" 2>/dev/null; then
        bad "clearnet egress is FAIL-OPEN — monerod reached 1.1.1.1 directly, bypassing Tor (the firewall is not enforced)"
        _egress_capture_diagnostics
    else
        ok "direct clearnet dial from a mining container is dropped — Tor-only egress is enforced"
    fi
    # POSITIVE — the SAME container still reaches clearnet THROUGH Tor's SOCKS, proving the drop
    # spares Tor and intra-subnet traffic (real mining keeps working) AND that the negative above
    # failed because of the firewall rather than because the guest has no route to the internet at
    # all. Tor's default SOCKS is 172.28.0.25:9050 on the appliance's mining_net.
    if _ssh "podman exec monerod curl -s -o /dev/null -m 30 --socks5-hostname 172.28.0.25:9050 http://1.1.1.1/" 2>/dev/null; then
        ok "egress through Tor's SOCKS still works — the drop did not break real mining"
    else
        bad "the mining container can no longer reach clearnet even through Tor — the firewall is too tight, or the guest has no route out (which would also void the drop above)"
        _egress_capture_diagnostics
    fi
    # IPv6 backstop (#858): mining_net is IPv4-only by design, so monerod has no global v6 and this
    # leg self-skips on the stock appliance. If mining_net ever gains a v6 subnet, the container CAN
    # originate v6 clearnet — assert that dial is DROPPED too (the fail-open the v4-only rules left
    # behind). Guarded on the container actually holding a global v6 address.
    if _ssh "podman exec monerod sh -c 'ip -6 addr show scope global 2>/dev/null | grep -q inet6'" 2>/dev/null; then
        if _ssh "podman exec monerod curl -s -o /dev/null -m 8 -g 'http://[2606:4700:4700::1111]/'" 2>/dev/null; then
            bad "IPv6 clearnet egress is FAIL-OPEN — monerod reached a v6 address directly, bypassing Tor"
            _egress_capture_diagnostics
        else
            ok "direct IPv6 clearnet dial from a mining container is dropped — the v6 backstop holds"
        fi
    else
        ok "mining_net is IPv4-only (no global v6 in the container) — v6 clearnet dial not possible, backstop not exercised"
    fi
    return 0
}

_egress_self_test() {
    local f=0 probes want label cmd
    probes=$(egress_diag_probes)
    # Every probe #2059 asked for, plus the engine verdict that tells the two failure modes apart.
    for want in engine nft-table nft-hook mining-net boot-log; do
        printf '%s\n' "$probes" | cut -f1 | grep -qxF "$want" || {
            printf 'missing probe: %s\n' "$want" >&2
            f=$((f + 1))
        }
    done
    # printf cycles its format, so ADDING a probe label without its command silently mis-shifts
    # every pair after it and leaves the last row commandless — probing nothing, forever.
    [ "$(grep -c "$(printf '\t.')" <<<"$probes")" = "$(grep -c . <<<"$probes")" ] || {
        printf 'a probe row carries no command — the label/command pairs are mis-shifted\n' >&2
        f=$((f + 1))
    }

    # The #2059 fix itself: an UNEXERCISED backstop must read RED on a green phase and must not
    # double-count on an already-red one. Driven, not grepped — a source check would pass on a
    # function that assigned the variable and then ignored it. Stub the guest away so the leg takes
    # its earliest unexercised path, and count what each arm actually reported.
    local PASS=0 FAIL=0
    _ssh() { return 1; }
    phase_provision_egress_backstop 0 >/dev/null
    [ "$FAIL" -eq 1 ] && [ "$PASS" -eq 0 ] || {
        printf 'unexercised backstop on a GREEN phase did not report FAIL (pass=%s fail=%s)\n' "$PASS" "$FAIL" >&2
        f=$((f + 1))
    }
    PASS=0 FAIL=0
    phase_provision_egress_backstop 1 >/dev/null
    [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 0 ] || {
        printf 'unexercised backstop on an ALREADY-RED phase double-counted (pass=%s fail=%s)\n' "$PASS" "$FAIL" >&2
        f=$((f + 1))
    }
    unset -f _ssh

    # The property #2059 is actually about: the backstop runs even when the provision body ABORTS,
    # and the body's rc still propagates (so an abort keeps stopping the reboot/migration legs).
    # Driven through the real caller with both halves stubbed — a source grep would still pass on a
    # wrapper that called the leg and then swallowed the rc, or that was never called at all.
    local caller
    caller="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/phases/provision-initial.sh"
    (
        OS_RUN_SUITE=1 ran=0
        # shellcheck source=tests/os/phases/provision-initial.sh
        . "$caller" # an unreachable caller fails here, which is the same verdict
        _provision_initial_body() { return 7; }
        phase_provision_egress_backstop() { ran=1; }
        _phase_provision_initial
        got=$?
        [ "$ran" = 1 ] && [ "$got" = 7 ]
    ) 2>/dev/null || {
        printf 'the egress backstop is not wired to run past a provision-body abort (or the rc no longer propagates)\n' >&2
        f=$((f + 1))
    }

    if [ "$f" -ne 0 ]; then
        printf 'appliance-egress-leg self-test FAILED: %s checks\n' "$f"
        return 1
    fi
    printf 'appliance-egress-leg self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = --self-test ]; then
    # The suite runner supplies these; a standalone self-test stands them up itself so the leg can
    # be DRIVEN rather than read. Same counter semantics as tests/os/lib/core.sh.
    ok() {
        PASS=$((PASS + 1))
        printf '  ok %s\n' "$1"
    }
    bad() {
        FAIL=$((FAIL + 1))
        printf '  bad %s\n' "$1"
    }
    info() { printf '==> %s\n' "$1"; }
    _egress_self_test
fi
