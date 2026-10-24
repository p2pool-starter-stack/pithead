#!/usr/bin/env bash
# Runs after unrelated provision failures so Tor-only egress enforcement is never silently skipped.

# shellcheck source=tests/integration/lib/tor-control-dial.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../integration/lib" && pwd)/tor-control-dial.sh"

# Distinguishes absent rules from ineffective rules, starting with the engine that selects the backend.
egress_diag_probes() { # -> "<label>\t<remote command>" per line
    printf '%s\t%s\n' \
        'engine' 'grep -h "^PITHEAD_ENGINE=" /etc/environment 2>/dev/null; cd /data/pithead 2>/dev/null && bash -c "source ./pithead && container_engine" 2>/dev/null' \
        'nft-table' 'nft list table inet pithead_egress 2>&1' \
        'nft-hook' 'nft list ruleset 2>/dev/null | grep -A20 pithead_egress' \
        'mining-net' 'podman network inspect mining_net 2>&1 | head -c 600' \
        'boot-log' 'journalctl -u pithead-boot --no-pager 2>/dev/null | grep -i egress | tail -5' \
        'firstboot-log' 'journalctl -u pithead-firstboot --no-pager 2>/dev/null | grep -i egress | tail -5'
}

# True when a /proc/net/if_inet6 dump holds a global-scope address. Its fourth column is the scope:
# 00 global, 10 host (::1), 20 link (fe80::).
egress_has_global_v6() { # <if_inet6 contents>
    awk '$4 == "00" { found = 1 } END { exit !found }' <<<"$1"
}

# Bounds excerpts because the harness forbids raw dumps in model context.
_egress_capture_diagnostics() {
    local label cmd out ran=0
    info "  egress diagnostics (#2059) — is the table ABSENT, or PRESENT but ineffective?"
    # Redirects stdin so SSH cannot consume the remaining probe list.
    while IFS=$'\t' read -r label cmd; do
        [ -n "$label" ] || continue
        out=$(_ssh "$cmd" </dev/null 2>/dev/null | tr '\n' ' ' | tr -s ' ' | cut -c1-220)
        info "    $label: ${out:-<empty>}"
        ran=$((ran + 1))
    done < <(egress_diag_probes)
    # A partial capture is worse than none: it looks like evidence while omitting the half that
    # decides the fix. Say so rather than letting the reader assume the missing probes came back empty.
    local want
    want=$(egress_diag_probes | grep -c .)
    [ "$ran" -eq "$want" ] ||
        info "    (INCOMPLETE: $ran of $want probes ran — treat the above as partial evidence)"
}

# An unexercised backstop fails an otherwise-green phase so missing enforcement cannot pass.
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
    # build/monero/Dockerfile installs curl, and apt puts it at this fixed path. Every probe below
    # names its executable by absolute path so no probe depends on the exec's PATH.
    local rc=0
    _ssh "podman exec monerod /usr/bin/curl --version >/dev/null 2>&1" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        # A probe that cannot run is unverified, never a pass: it stays a distinct failure even when
        # an earlier provision assertion already made the phase red. The rc tells a missing binary
        # (127) from a podman error such as monerod exiting since the wait above (125).
        bad "could not run /usr/bin/curl in monerod (rc=$rc) — cannot assert the Tor-only egress drop (the #855 backstop is unverified)"
        return 0
    fi

    # NEGATIVE — a direct clearnet dial by IP must be DROPPED. This is the check whose absence let
    # a leaking appliance ship green: it FAILS against the orphaned-chain code and PASSES once the
    # nft table is installed and effective. The rule is a silent `drop`, so a refused dial is a
    # curl timeout (28). Any other failure (podman 125, ssh 255) is a dial that never ran.
    rc=0
    _ssh "podman exec monerod /usr/bin/curl -s -o /dev/null -m 8 http://1.1.1.1/" 2>/dev/null || rc=$?
    case "$rc" in
    0)
        bad "clearnet egress is FAIL-OPEN — monerod reached 1.1.1.1 directly, bypassing Tor (the firewall is not enforced)"
        _egress_capture_diagnostics
        ;;
    28) ok "direct clearnet dial from a mining container is dropped — Tor-only egress is enforced" ;;
    *) bad "the direct clearnet dial from monerod failed without timing out (rc=$rc) — the Tor-only egress drop is unverified" ;;
    esac
    # POSITIVE — the SAME container still reaches clearnet THROUGH Tor's SOCKS, proving the drop
    # spares Tor and intra-subnet traffic (real mining keeps working) AND that the negative above
    # failed because of the firewall rather than because the guest has no route to the internet at
    # all. Tor's default SOCKS is 172.28.0.25:9050 on the appliance's mining_net.
    local attempt=1 tried=""
    while [ "$attempt" -le "$TOR_CONTROL_DIAL_ATTEMPTS" ]; do
        rc=0
        _ssh "$(tor_control_dial_cmd podman /usr/bin/curl 172.28.0.25:9050 "$attempt")" 2>/dev/null || rc=$?
        [ "$rc" -ne 0 ] || break
        tried="${tried:+$tried; }attempt $attempt exit=$rc"
        attempt=$((attempt + 1))
    done
    if [ "$rc" -eq 0 ]; then
        ok "egress through Tor's SOCKS still works — the drop did not break real mining${tried:+ (passed on attempt $attempt of $TOR_CONTROL_DIAL_ATTEMPTS; $tried)}"
    else
        bad "the mining container can no longer reach clearnet even through Tor (all $TOR_CONTROL_DIAL_ATTEMPTS attempts failed; $tried) — the firewall is too tight, or the guest has no route out (which would also void the drop above)"
        _egress_capture_diagnostics
    fi
    # IPv6 backstop (#858): mining_net is IPv4-only by design, so monerod has no global v6 and this
    # leg self-skips on the stock appliance. If mining_net ever gains a v6 subnet, the container CAN
    # originate v6 clearnet — assert that dial is DROPPED too (the fail-open the v4-only rules left
    # behind). Guarded on the container actually holding a global v6 address. The guard reads the
    # kernel's own table with the image's cat: the image ships no `ip`, and a guard that cannot run
    # must fail rather than report the IPv4-only pass below (bench-ci#532).
    local inet6
    rc=0
    inet6=$(_ssh "podman exec monerod /usr/bin/cat /proc/net/if_inet6" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        bad "could not read /proc/net/if_inet6 in monerod (rc=$rc) — the IPv6 egress backstop is unverified"
    elif egress_has_global_v6 "$inet6"; then
        rc=0
        _ssh "podman exec monerod /usr/bin/curl -s -o /dev/null -m 8 -g 'http://[2606:4700:4700::1111]/'" 2>/dev/null || rc=$?
        case "$rc" in
        0)
            bad "IPv6 clearnet egress is FAIL-OPEN — monerod reached a v6 address directly, bypassing Tor"
            _egress_capture_diagnostics
            ;;
        28) ok "direct IPv6 clearnet dial from a mining container is dropped — the v6 backstop holds" ;;
        *) bad "the direct IPv6 dial from monerod failed without timing out (rc=$rc) — the v6 backstop is unverified" ;;
        esac
    else
        ok "mining_net is IPv4-only (no global v6 in the container) — v6 clearnet dial not possible, backstop not exercised"
    fi
    # The dashboard's view of the same backstop (#2599): pithead-egress.timer (rendered into /run each
    # boot, OnBootSec=2min) must be active, and its read-only check must have written rc 0.
    if [ "$(_ssh 'systemctl is-active pithead-egress.timer' 2>/dev/null)" = active ]; then
        ok "pithead-egress.timer is active on the appliance — the dashboard gets the live firewall verdict (#2599)"
    else
        bad "pithead-egress.timer is not active on the appliance — the dashboard shows the egress firewall as unverified (#2599)"
    fi
    local status deadline=$(($(date +%s) + ${EGRESS_STATUS_TIMEOUT:-240}))
    until status=$(_ssh "jq -c '[.rc, .verdict]' /data/pithead/data/control/results/egress-status.json" 2>/dev/null) &&
        [ "$status" = '[0,"enforced"]' ] || [ "$(date +%s)" -ge "$deadline" ]; do sleep 10; done
    if [ "$status" = '[0,"enforced"]' ]; then
        ok "the host check wrote rc 0 (enforced) for the dashboard (#2599)"
    else
        bad "the host check did not write an enforced verdict for the dashboard (got: ${status:-no file}) (#2599)"
        _egress_capture_diagnostics
    fi
    return 0
}

# Drive the leg against a stubbed guest in a subshell, so the stubs and counters never leak into the
# caller. Prints one line per guest command (`call ...`) and per reported row (`ok ...`/`bad ...`).
# <guest>: unreachable | no-curl (curl exits 127) | no-cat (cat exits 127) | v4-only | global-v6 |
# dial-lost (both direct dials die in podman, 125) | dial-refused (both are refused, curl 7) |
# fail-open (both connect) | tor-down (SOCKS dials fail, curl 7) | tor-flaky (two SOCKS dials fail, curl 52) | no-status (no #2599 timer or file).
# All but v4-only hold a global v6 address. Otherwise well behaved: direct dials time out (28), the
# Tor SOCKS dial succeeds, the timer is active and the status file reads enforced.
_egress_drive() { # <phase-rc> <guest>
    (
        guest=$2 EGRESS_STATUS_TIMEOUT=0 socks_calls=0
        ok() { printf 'ok %s\n' "$1"; }
        bad() { printf 'bad %s\n' "$1"; }
        info() { :; }
        _egress_capture_diagnostics() { :; }
        _ssh() {
            printf 'call %s\n' "$1" >&3 # the leg sends _ssh's stderr to /dev/null
            [ "$guest" != unreachable ] || return 1
            case "$1" in
            true) return 0 ;;
            *"podman ps"*) printf 'monerod\n' ;;
            *"is-active pithead-egress.timer"*) [ "$guest" = no-status ] || printf 'active\n' ;;
            *egress-status.json*) [ "$guest" = no-status ] || printf '[0,"enforced"]\n' ;;
            *--socks5-hostname*)
                socks_calls=$((socks_calls + 1))
                case "$guest" in
                tor-down) return 7 ;;
                tor-flaky) [ "$socks_calls" -ge 3 ] || return 52 ;;
                esac
                ;;
            *"/usr/bin/curl --version"*) [ "$guest" != no-curl ] || return 127 ;;
            *"/usr/bin/cat /proc/net/if_inet6"*)
                [ "$guest" != no-cat ] || return 127
                printf '00000000000000000000000000000001 01 80 10 80       lo\n'
                printf 'fe800000000000000000000000000001 02 40 20 80     eth0\n'
                [ "$guest" = v4-only ] ||
                    printf 'fd000000000000000000000000000002 02 40 00 00     eth0\n'
                ;;
            *"/usr/bin/curl -s -o /dev/null -m 8 "*)
                case "$guest" in
                dial-lost) return 125 ;;
                dial-refused) return 7 ;;
                fail-open) return 0 ;;
                *) return 28 ;;
                esac
                ;;
            *) return 1 ;;
            esac
        }
        phase_provision_egress_backstop "$1"
    ) 3>&1
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
    # its earliest unexercised path, and read what each arm actually reported.
    local out
    out=$(_egress_drive 0 unreachable)
    [ "$(grep -c '^bad ' <<<"$out")" = 1 ] && ! grep -q '^ok ' <<<"$out" || {
        printf 'unexercised backstop on a GREEN phase did not report FAIL: %s\n' "$out" >&2
        f=$((f + 1))
    }
    out=$(_egress_drive 1 unreachable)
    ! grep -qE '^(ok|bad) ' <<<"$out" || {
        printf 'unexercised backstop on an ALREADY-RED phase double-counted: %s\n' "$out" >&2
        f=$((f + 1))
    }

    # bench-ci#532: a probe executable that cannot run is a counted failure, never a pass, on a
    # green phase and on an already-red one alike. Once for curl, once for the v6 guard's cat.
    local phase_rc
    for phase_rc in 0 1; do
        out=$(_egress_drive "$phase_rc" no-curl)
        grep -q '^bad could not run /usr/bin/curl in monerod (rc=127)' <<<"$out" &&
            ! grep -q '^ok ' <<<"$out" || {
            printf 'a missing /usr/bin/curl did not fail the backstop (phase rc %s): %s\n' "$phase_rc" "$out" >&2
            f=$((f + 1))
        }
        out=$(_egress_drive "$phase_rc" no-cat)
        grep -q '^bad could not read /proc/net/if_inet6 in monerod (rc=127)' <<<"$out" &&
            ! grep -q '^ok .*IPv4-only' <<<"$out" || {
            printf 'a v6 guard that could not run reported a pass (phase rc %s): %s\n' "$phase_rc" "$out" >&2
            f=$((f + 1))
        }
    done
    # The guard reads the kernel's scope column: loopback and link-local alone are IPv4-only, and a
    # global address sends the leg into the v6 dial.
    out=$(_egress_drive 0 v4-only)
    grep -q '^ok mining_net is IPv4-only' <<<"$out" && ! grep -q '^bad ' <<<"$out" &&
        ! grep -q '2606:4700' <<<"$out" || {
        printf 'a container with only lo and link-local v6 was not read as IPv4-only: %s\n' "$out" >&2
        f=$((f + 1))
    }
    out=$(_egress_drive 0 no-status) # #2599: red when no timer or status file exists
    grep -q '^bad pithead-egress.timer is not active' <<<"$out" &&
        grep -q '^bad the host check did not write an enforced verdict' <<<"$out" || {
        printf 'a guest with no egress-status timer or file was not reported: %s\n' "$out" >&2
        f=$((f + 1))
    }
    out=$(_egress_drive 0 global-v6)
    grep -q "^call podman exec monerod /usr/bin/curl .*2606:4700" <<<"$out" &&
        grep -q '^ok direct IPv6 clearnet dial from a mining container is dropped' <<<"$out" || {
        printf 'a container with a global v6 address did not run the v6 dial: %s\n' "$out" >&2
        f=$((f + 1))
    }
    # Only a timeout is a drop: a direct dial that never ran, or that something other than the silent
    # drop refused, must not read as one, on either family.
    local guest rc_want
    for guest in dial-lost:125 dial-refused:7; do
        rc_want=${guest#*:}
        out=$(_egress_drive 0 "${guest%:*}")
        [ "$(grep -c "^bad .*failed without timing out (rc=$rc_want)" <<<"$out")" = 2 ] &&
            ! grep -q '^ok .*dropped' <<<"$out" || {
            printf 'a direct dial that exited %s was reported as dropped: %s\n' "$rc_want" "$out" >&2
            f=$((f + 1))
        }
    done
    # The verdicts themselves: a dial that connects is FAIL-OPEN on both families, and a Tor path
    # that fails is red, however green the drop looks.
    out=$(_egress_drive 0 fail-open)
    grep -q '^bad clearnet egress is FAIL-OPEN' <<<"$out" &&
        grep -q '^bad IPv6 clearnet egress is FAIL-OPEN' <<<"$out" &&
        ! grep -q '^ok .*dropped' <<<"$out" || {
        printf 'a direct dial that connected was not reported FAIL-OPEN: %s\n' "$out" >&2
        f=$((f + 1))
    }
    out=$(_egress_drive 0 tor-down)
    grep -q '^bad the mining container can no longer reach clearnet even through Tor' <<<"$out" &&
        ! grep -q "^ok egress through Tor's SOCKS" <<<"$out" || {
        printf 'a failed Tor SOCKS dial was not reported: %s\n' "$out" >&2
        f=$((f + 1))
    }
    # Every exec names its executable by absolute path, so no probe depends on the exec's PATH.
    if grep '^call podman exec' <<<"$out" | grep -qv '^call podman exec monerod /usr/bin/'; then
        printf 'a monerod probe is not pinned to an absolute /usr/bin path: %s\n' "$out" >&2
        f=$((f + 1))
    fi
    [ "$(grep -c '^call podman exec monerod /usr/bin/curl -s' <<<"$out")" = 5 ] || {
        printf 'expected five pinned curl dials (v4 direct, three Tor SOCKS attempts, v6 direct): %s\n' "$out" >&2
        f=$((f + 1))
    }
    grep -q 'all 3 attempts failed; attempt 1 exit=7; attempt 2 exit=7; attempt 3 exit=7' <<<"$out" || {
        printf 'a dead Tor path did not name all three attempts: %s\n' "$out" >&2
        f=$((f + 1))
    }
    # One bad exit is a flake (#2619): retries carry their own SOCKS user and a success stops the loop.
    out=$(_egress_drive 0 tor-flaky)
    grep -q "^ok egress through Tor's SOCKS still works.*passed on attempt 3 of 3; attempt 1 exit=52; attempt 2 exit=52" <<<"$out" &&
        ! grep -q '^bad ' <<<"$out" &&
        grep -q '^call podman exec monerod /usr/bin/curl -s -o /dev/null -m 30 --socks5-hostname 172.28.0.25:9050 http://1.1.1.1/$' <<<"$out" &&
        [ "$(grep -c -- '--proxy-user' <<<"$out")" = 2 ] &&
        [ "$(grep -- '--proxy-user' <<<"$out" | grep -o 'pithead-control-[^ ]*' | sort -u | wc -l | tr -d ' ')" = 2 ] || {
        printf 'two failed Tor attempts then a success was not a pass on fresh SOCKS users: %s\n' "$out" >&2
        f=$((f + 1))
    }
    out=$(_egress_drive 0 v4-only)
    [ "$(grep -c -- '--socks5-hostname' <<<"$out")" = 1 ] || {
        printf 'a first-attempt success still retried: %s\n' "$out" >&2
        f=$((f + 1))
    }

    # EVERY probe must run. The self-test missed this once and a real battery paid for it: the stub
    # below now CONSUMES STDIN, which is what real ssh does and what silently truncated the capture
    # to a single probe. A stub that does not read stdin cannot reproduce the defect, so it is the
    # stub — not the assertion — that makes this test real.
    local ran probes_n
    _ssh() {
        cat >/dev/null 2>&1 # ssh drains stdin; that is the whole bug
        printf 'stub-output\n'
    }
    ran=$(_egress_capture_diagnostics 2>&1 | grep -c ': ')
    probes_n=$(egress_diag_probes | grep -c .)
    [ "$ran" -eq "$probes_n" ] || {
        printf 'diagnostics ran %s of %s probes — ssh is eating the probe list again\n' "$ran" "$probes_n" >&2
        f=$((f + 1))
    }
    unset -f _ssh

    # The property #2059 is actually about: the backstop runs even when the provision body ABORTS,
    # and the body's rc still propagates (so an abort keeps stopping the reboot/migration legs).
    # Drive the real caller with stubbed halves; a source grep cannot prove execution or rc propagation.
    local caller
    caller="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/phases/provision-initial.sh"
    (
        # shellcheck disable=SC2034 # sourced phase reads the suite marker and runner path.
        OS_RUN_SUITE=1 SCRIPT_DIR="${caller%/phases/*}" ran=0
        # shellcheck source=tests/os/phases/provision-initial.sh
        . "$caller" # an unreachable caller fails here, which is the same verdict
        _phase_provision_initial_body() { return 7; }
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
