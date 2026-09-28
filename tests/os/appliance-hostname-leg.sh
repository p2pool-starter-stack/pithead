#!/usr/bin/env bash
# Hostname assertions for the provisioned appliance (#1957/#1966). Sourced by tests/os/run.sh;
# --self-test exercises the pure identity verdict without a guest.

hostname_identity_verdict() { # <label> <ip> <kernel> <static> <env-host> <state-host> <cert-san> <avahi-state> <mdns-ip> <card> <named-code>
    local label="$1" ip="$2" kernel="$3" static="$4" env_host="$5" state_host="$6" sans="$7" avahi="$8" mdns="$9"
    local card="${10}" named_code="${11}"
    [ "$kernel" = "$label" ] || {
        printf 'kernel=%s' "${kernel:-empty}"
        return 1
    }
    # The static name (#2350): a rename that only ever touched the transient kernel hostname left
    # `hostnamectl --static` — and anything that reads identity off it rather than the live kernel
    # value — answering the OLD name forever, reboot or not.
    [ "$static" = "$label" ] || {
        printf 'static=%s' "${static:-empty}"
        return 1
    }
    [ "$env_host" = "$label.local" ] || {
        printf 'env=%s' "${env_host:-empty}"
        return 1
    }
    [ "$state_host" = "$label.local" ] || {
        printf 'state=%s' "${state_host:-empty}"
        return 1
    }
    sans="${sans#*Subject Alternative Name:}"
    if ! printf '%s\n' "$sans" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF "DNS:$label.local"; then
        printf 'cert-missing-dns'
        return 1
    fi
    if ! printf '%s\n' "$sans" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF "IP Address:$ip"; then
        printf 'cert-missing-ip'
        return 1
    fi
    [ "$avahi" = active ] || {
        printf 'avahi=%s' "${avahi:-empty}"
        return 1
    }
    [ "$mdns" = "$ip" ] || {
        printf 'mdns=%s' "${mdns:-empty}"
        return 1
    }
    # The two the operator actually acts on (#2350). The card is the pair of addresses the machine
    # hands them — the wizard's credentials card at first boot, the console announcement's own
    # source afterwards — and it named `pithead.local` on a box the operator had just called
    # something else. Both halves are asserted: a dashboard address that is right while the
    # stratum still points at the old name sends every rig to a host that no longer answers.
    case " $card " in *" https://$label.local "*) ;; *)
        printf 'card-dashboard=%s' "${card:-empty}"
        return 1
        ;;
    esac
    case " $card " in *" stratum+tcp://$label.local:"*) ;; *)
        printf 'card-stratum=%s' "${card:-empty}"
        return 1
        ;;
    esac
    # And the name has to ANSWER, not just be advertised: the address on the card, dialled.
    case "$named_code" in 2?? | 3?? | 401 | 403) ;; *)
        printf 'named-http=%s' "${named_code:-empty}"
        return 1
        ;;
    esac
    printf 'ready'
}

# Every field the verdict short-circuits past, want beside got, so a failed row names all nine
# rather than only the first one to disagree (#2060). The certificate SANs and the card are
# squeezed onto the single line; an unread field reads `empty`, never as a gap in the line.
hostname_identity_payload() { # <label> <ip> <kernel> <static> <env-host> <state-host> <cert-san> <avahi-state> <mdns-ip> <card> <named-code>
    printf 'want kernel=%s static=%s env=%s state=%s cert=DNS:%s+IP:%s avahi=active mdns=%s card=https://%s+stratum+tcp://%s:<port> named-http=2xx/3xx/401/403 | got kernel=%s static=%s env=%s state=%s cert=%s avahi=%s mdns=%s card=%s named-http=%s' \
        "$1" "$1" "$1.local" "$1.local" "$1.local" "$2" "$2" "$1.local" "$1.local" \
        "${3:-empty}" "${4:-empty}" "${5:-empty}" "${6:-empty}" \
        "$(printf '%s' "${7:-empty}" | tr -s '[:space:]' ' ')" "${8:-empty}" "${9:-empty}" \
        "$(printf '%s' "${10:-empty}" | tr -s '[:space:]' ' ')" "${11:-empty}"
}

# What Avahi published and WHERE, read from the guest at the moment the row fails (#2060). The
# mDNS answers seen so far — 10.89.0.1 in one run, 172.28.0.1 in the next — are container-bridge
# addresses that move between runs, so the discriminator is the interface each address record was
# registered on, not the address. Avahi's own journal lines are the only place that pair appears
# ("Registering new address record for <addr> on <iface>.IPv4"), and the image ships no
# avahi-utils, so nothing here needs a package the appliance does not have.
# `ip -4 -o addr show scope global` -> "<iface> <addr>/<len> " pairs, one line. This is the field
# the whole dump exists for: it is what turns `mdns=10.89.0.1` into "10.89.0.1 is on podman1", and
# it answers that WITHOUT the journal, so a boot whose avahi lines have rotated still says which
# interface owns the address. Extracted only so it can be driven against canned `ip` output — the
# harness host is not always Linux, and an unnoticed change to the field layout would leave the
# dump printing nothing useful on the one row that needs it.
_addr_iface_map() { tr -d '\r' | sed 's/  */ /g' | cut -d' ' -f2,4 | tr '\n' ' '; }

hostname_mdns_evidence() { # <label>
    # _ssh's own default ceiling is 5400s. A row that already failed must not be able to spend
    # ninety minutes per probe collecting the evidence for its own failure. _ssh reads this
    # through Bash's dynamic scope.
    # shellcheck disable=SC2034
    local SSH_TIMEOUT=30
    printf '     --- mDNS evidence (#2060) ---\n'
    # Reachability first, host-side. Every fallback below runs on the GUEST, so a dead transport
    # skips all of them and five probes print five blank fields — identical to a live guest that
    # answered empty. That is the defect this whole change exists to remove, one level up.
    if ! _ssh true; then
        printf '     the guest did not answer, so no mDNS evidence could be read (ssh: %s)\n' \
            "$(tr -d '\r' <"${SSH_ERR:-/dev/null}" 2>/dev/null | tail -1)"
        return 0
    fi
    printf '     getent ahostsv4: %s\n' "$(_ssh "getent ahostsv4 '$1.local' 2>&1 | head -4" 2>/dev/null | tr -d '\r' | tr '\n' ';')"
    printf '     global v4 addresses: %s\n' "$(_ssh 'ip -4 -o addr show scope global' 2>/dev/null | _addr_iface_map)"
    printf '     default route: %s\n' "$(_ssh 'ip -4 route show default' 2>/dev/null | tr -d '\r' | tr '\n' ';')"
    printf '     avahi interface config: %s\n' "$(_ssh "grep -E '^[[:space:]]*(allow|deny)-interfaces|^[[:space:]]*use-ipv[46]' /etc/avahi/avahi-daemon.conf || echo 'no interface line — every interface'" 2>/dev/null | tr -d '\r' | tr '\n' ';')"
    printf '     avahi address records (address and interface, newest last):\n'
    # `grep .` turns an empty match into a sentence. With the reachability probe above, this
    # fallback now has exactly ONE meaning left — the guest answered and the journal has no such
    # lines — so it must not offer the transport as an alternative it has already ruled out.
    # The dump does not depend on this: `getent` above gives the ADDRESS and `ip -4 -o addr` gives
    # the interface it belongs to, which is the pair the row needs. The journal only corroborates.
    _ssh "journalctl -u avahi-daemon.service -b --no-pager 2>/dev/null | grep -aE 'address record|relevant interface|Withdrawing' | tail -n 20 | grep . || echo 'no avahi address-record lines in this boot journal — the probe above proved the guest answers, so this is the journal, not the transport; read the address-to-interface mapping instead'" 2>/dev/null |
        tr -d '\r' | sed 's/^/     | /'
}

# The pair of addresses this machine hands the operator, which must name the box it actually
# became (#2350). Two sources, one meaning. At wizard completion it is handoff.json — the card
# the operator reads, and the artifact the issue was filed against — passed in by the leg that
# captured it; that file is written once and never rewritten, so it cannot speak for a box
# renamed later. Every later point composes the same card from the same two files the console
# announcement reads it out of: HOST_IP in .env (13-announce.sh's `announce_dashboard_url`) and
# the stratum port in config.json (the wizard's own stratum line). So the day-two point is not
# reading a stale record, it is reading what the machine would tell an operator NOW.
hostname_card_addresses() { # [handoff-json]; "<dashboard> <stratum>"
    local card="${1:-}" host port
    if [ -n "$card" ]; then
        printf '%s %s' "$(printf '%s' "$card" | jq -r '.dashboard // ""' 2>/dev/null)" \
            "$(printf '%s' "$card" | jq -r '.stratum // ""' 2>/dev/null)"
        return 0
    fi
    host=$(_ssh "sed -n 's/^HOST_IP=//p' /data/pithead/.env" 2>/dev/null | tr -d '\r')
    port=$(_ssh "jq -r '.p2pool.stratum_port // 3333' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ -n "$host" ] || return 0 # nothing rendered yet: an empty card fails the verdict, never passes it
    printf 'https://%s stratum+tcp://%s:%s' "$host" "$host" "${port:-3333}"
}

# The card's address, dialled. `--resolve` stands in for the operator's own mDNS lookup: the
# harness host does not run Avahi, and what is under test is that the NAME the machine published
# is the name its TLS and its vhost answer to, not that this host can resolve .local.
hostname_named_http_code() { # <label>
    curl -ksS --resolve "$1.local:443:$ip" -o /dev/null -w '%{http_code}' -m 8 "https://$1.local/" 2>/dev/null || true
}

hostname_runtime_snapshot() { # <label> [handoff-json]; one stable, comparable line
    local label="$1" card_src="${2:-}" kernel static env_host state_host sans avahi mdns card stamp
    kernel=$(_ssh 'hostname' 2>/dev/null | tr -d '\r')
    static=$(_ssh 'hostnamectl --static' 2>/dev/null | tr -d '\r')
    card=$(hostname_card_addresses "$card_src")
    env_host=$(_ssh "sed -n 's/^HOST_IP=//p' /data/pithead/.env" 2>/dev/null | tr -d '\r')
    state_host=$(dashboard_curl -fsSk -m 8 "https://$ip/api/state" 2>/dev/null | jq -r '.host_ip // ""')
    sans=$(openssl s_client -connect "$ip:443" -servername "$label.local" </dev/null 2>/dev/null |
        openssl x509 -noout -ext subjectAltName 2>/dev/null | tr '\n' ' ')
    avahi=$(_ssh 'systemctl is-active avahi-daemon.service' 2>/dev/null | tr -d '\r')
    mdns=$(_ssh "getent ahostsv4 '$label.local' | awk 'NR == 1 {print \$1}'" 2>/dev/null | tr -d '\r')
    stamp=$(_ssh "systemctl show avahi-daemon.service -p ActiveEnterTimestampMonotonic --value" 2>/dev/null | tr -d '\r')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kernel" "$static" "$env_host" "$state_host" "$sans" "$avahi" "$mdns" "$card" "$stamp"
}

# <handoff-json> is the wizard's own credentials card, and only the leg that captured it has one;
# every later caller leaves it off and the card is composed from the live source instead. The HTTP
# probe is deliberately NOT part of the snapshot: the snapshot doubles as the before/after
# comparison for the day-two preview, where a status code is noise rather than a side effect.
assert_appliance_hostname_identity() { # <label> <context> <dashboard-user> <dashboard-password> [handoff-json]
    local label="$1" context="$2" tries=0 snap verdict="" named_code=""
    # dashboard_curl reads these through Bash's dynamic scope.
    # shellcheck disable=SC2034
    local DASH_USER="$3" DASH_PASS="$4" card_src="${5:-}"
    while [ "$tries" -lt 12 ]; do
        snap=$(hostname_runtime_snapshot "$label" "$card_src")
        IFS=$'\t' read -r kernel static env_host state_host sans avahi mdns card _stamp <<<"$snap"
        named_code=$(hostname_named_http_code "$label")
        verdict=$(hostname_identity_verdict "$label" "$ip" "$kernel" "$static" "$env_host" "$state_host" "$sans" "$avahi" "$mdns" "$card" "$named_code") && {
            ok "$context names $label everywhere it is read: kernel and static hostname, rendered dashboard, certificate, mDNS, the card's dashboard and stratum addresses, and https://$label.local answering (HTTP $named_code)"
            return 0
        }
        tries=$((tries + 1))
        sleep 5
    done
    hostname_mdns_evidence "$label"
    bad "$context identity did not converge (${verdict:-unknown}) — $(hostname_identity_payload "$label" "$ip" "$kernel" "$static" "$env_host" "$state_host" "$sans" "$avahi" "$mdns" "$card" "$named_code"); mDNS evidence above"
    return 1
}

phase_provision_hostname_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" before after live proposed preview
    # The card the operator actually read is the wizard's own handoff, and it exists only here —
    # $handoff_body is the initial leg's local, reached the way pv_user/pv_pass are (#2350). Hand
    # it to the shared verdict so the wizard point judges the real artifact; every later point
    # composes the same card from the live source instead.
    # shellcheck disable=SC2154  # handoff_body is the initial leg's local (dynamic scope)
    assert_appliance_hostname_identity fixture-box "wizard hostname" "$DASH_USER" "$DASH_PASS" "$handoff_body" || return

    # Preview is pure even though this name change requires the combined configuration approval
    # path. Compare the privileged side effects as well as config: a dry-run that restarted Avahi
    # or minted a certificate would be visible here even if config.json stayed unchanged.
    before=$(hostname_runtime_snapshot fixture-box)
    live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) || {
        bad "hostname preview: live config could not be read"
        return
    }
    proposed=$(printf '%s' "$live" | jq -c '.dashboard.host = "fixture-next"')
    preview=$(dashboard_control_request preview "$(jq -nc --argjson config "$proposed" '{config:$config}')")
    after=$(hostname_runtime_snapshot fixture-box)
    if printf '%s' "$preview" | jq -e '.status == "previewed" and .approval_required == true' >/dev/null &&
        [ "$before" = "$after" ] && dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null |
        jq -e '.dashboard.host == "fixture-box"' >/dev/null; then
        ok "day-two hostname preview is approval-gated and has no hostname, mDNS or certificate side effect"
    else
        bad "day-two hostname preview mutated identity or missed its approval gate"
    fi
}

_hostname_self_test() {
    local good='DNS:fixture-box.local, IP Address:192.0.2.10' f=0
    local card='https://fixture-box.local stratum+tcp://fixture-box.local:3333'
    local stale='https://pithead.local stratum+tcp://pithead.local:3333'
    [ "$(hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 "$card" 401)" = ready ] || f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 old fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 "$card" 401 >/dev/null && f=$((f + 1))
    # The static name (#2350): a kernel hostname that renamed clean but left `hostnamectl --static`
    # on the old name must fail too — this is the exact defect the field was added to catch.
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box pithead fixture-box.local fixture-box.local "$good" active 192.0.2.10 "$card" 401 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local 'DNS:fixture-box.local' active 192.0.2.10 "$card" 401 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local 'DNS:fixture-box.local.evil, IP Address:192.0.2.100' active 192.0.2.10 "$card" 401 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" inactive 192.0.2.10 "$card" 401 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.11 "$card" 401 >/dev/null && f=$((f + 1))
    # #2350 as the operator met it: every name on the box is right and the CARD still reads
    # pithead.local. Each half alone must red the row — a card whose dashboard address was fixed
    # while its stratum still named the old box is the same bug, half-fixed.
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 "$stale" 401 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 'https://fixture-box.local stratum+tcp://pithead.local:3333' 401 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 'https://pithead.local stratum+tcp://fixture-box.local:3333' 401 >/dev/null && f=$((f + 1))
    # A near-miss must not pass on a substring: fixture-box.local.evil is not fixture-box.local.
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 'https://fixture-box.local.evil stratum+tcp://fixture-box.local.evil:3333' 401 >/dev/null && f=$((f + 1))
    # An empty card is the unread field, and it must fail rather than vacuously pass the case.
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 '' 401 >/dev/null && f=$((f + 1))
    # The name must ANSWER. 000 is what curl prints when nothing accepted the connection.
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 "$card" 000 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 "$card" 502 >/dev/null && f=$((f + 1))
    for code in 200 302 401 403; do
        [ "$(hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10 "$card" "$code")" = ready ] || f=$((f + 1))
    done
    # The card helper's own two sources. The wizard's card is read from the JSON the operator saw;
    # with none passed the live source composes the same pair off .env and config.json, which is
    # the ONLY reading available once the wizard's one-time card can no longer speak for the name.
    [ "$(hostname_card_addresses '{"dashboard":"https://fixture-box.local","stratum":"stratum+tcp://fixture-box.local:3333"}')" = "$card" ] || f=$((f + 1))
    # shellcheck disable=SC2317  # called through hostname_card_addresses below
    _ssh() {
        case "$*" in
        *HOST_IP*) printf 'fixture-next.local\n' ;;
        *stratum_port*) printf '3333\n' ;;
        esac
    }
    [ "$(hostname_card_addresses)" = 'https://fixture-next.local stratum+tcp://fixture-next.local:3333' ] || f=$((f + 1))
    # Nothing rendered yet must NOT compose a card out of an empty host: "https:// stratum+tcp://:"
    # would carry the label nowhere and read as a card that merely failed one half.
    # shellcheck disable=SC2317  # called through hostname_card_addresses below
    _ssh() { :; }
    [ -z "$(hostname_card_addresses)" ] || f=$((f + 1))
    unset -f _ssh
    # The payload the failing rows now carry. A verdict names ONE field; #2060's three rows needed
    # all of them, so assert both sides of the pair the verdict short-circuited on, and that an
    # unread field prints `empty` rather than collapsing the line.
    local payload
    payload=$(hostname_identity_payload fixture-box 192.0.2.10 fixture-box fixture-box fixture-box.local fixture-box.local "$good" active 10.89.0.1 "$stale" 000)
    case "$payload" in *'mdns=192.0.2.10'*) ;; *) f=$((f + 1)) ;; esac
    case "$payload" in *'mdns=10.89.0.1'*) ;; *) f=$((f + 1)) ;; esac
    case "$payload" in *'static=fixture-box'*) ;; *) f=$((f + 1)) ;; esac
    case "$payload" in *'cert=DNS:fixture-box.local+IP:192.0.2.10'*) ;; *) f=$((f + 1)) ;; esac
    # The card is the field #2350 is about: the failing row must print what the operator was told,
    # beside what it should have said, or the row names a defect nobody can act on.
    case "$payload" in *'card=https://pithead.local stratum+tcp://pithead.local:3333'*) ;; *) f=$((f + 1)) ;; esac
    case "$payload" in *'card=https://fixture-box.local+stratum+tcp://fixture-box.local:<port>'*) ;; *) f=$((f + 1)) ;; esac
    case "$payload" in *'named-http=000'*) ;; *) f=$((f + 1)) ;; esac
    payload=$(hostname_identity_payload fixture-box 192.0.2.10 "" "" "" "" "" "" "" "" "")
    case "$payload" in *'kernel=empty'*'static=empty'*'cert=empty'*'avahi=empty'*'mdns=empty'*'card=empty'*'named-http=empty'*) ;; *) f=$((f + 1)) ;; esac
    # A guest that is GONE and a guest that answered EMPTY must not print the same evidence. They
    # did: the per-probe fallbacks all run on the guest, so a dead transport skipped every one and
    # both cases printed five blank fields. Both directions are asserted, since only the pair
    # proves discrimination — either sentence alone can be produced by a stuck instrument.
    local dead alive
    # shellcheck disable=SC2317  # called through the shim below
    _ssh() { return 255; }
    dead=$(hostname_mdns_evidence fixture-box)
    # The live shim answers the `ip` probe with real `ip -4 -o addr` output, so this asserts the
    # dump's OWN line, not just the helper. A control that drives the helper alone is blind to
    # PLACEMENT: dropping `| _addr_iface_map` from the dump left such a control fully green.
    # shellcheck disable=SC2317
    _ssh() {
        case "$*" in
        *'ip -4 -o addr'*) printf '%s\n' \
            '3: podman1    inet 10.89.0.1/24 brd 10.89.0.255 scope global podman1\       valid_lft forever' ;;
        *getent*) printf '10.89.0.1 STREAM fixture-box.local\n' ;;
        esac
    }
    alive=$(hostname_mdns_evidence fixture-box)
    # The issue asks for two things: what Avahi RESOLVED and WHICH INTERFACE it is on. Assert both
    # halves off the dump's own lines — emptying either one left every other control green.
    case "$alive" in *'getent ahostsv4: 10.89.0.1 STREAM fixture-box.local'*) ;; *) f=$((f + 1)) ;; esac
    case "$alive" in *'global v4 addresses: podman1 10.89.0.1/24'*) ;; *) f=$((f + 1)) ;; esac
    case "$alive" in *valid_lft*) f=$((f + 1)) ;; esac
    unset -f _ssh
    # The address-to-interface map, against real `ip -4 -o addr` output. #2060's two observed mDNS
    # answers must each come back named with the interface that owns them — that pairing is the
    # whole point of the dump, and it is the one thing a fix by interface cannot be written without.
    local ipout
    ipout=$(printf '%s\n' \
        '2: enp1s0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic enp1s0\       valid_lft 84559sec' \
        '3: podman1    inet 10.89.0.1/24 brd 10.89.0.255 scope global podman1\       valid_lft forever' \
        '4: cni-podman0    inet 172.28.0.1/16 brd 172.28.255.255 scope global cni-podman0\       valid_lft forever' |
        _addr_iface_map)
    case "$ipout" in *'podman1 10.89.0.1/24'*) ;; *) f=$((f + 1)) ;; esac
    case "$ipout" in *'cni-podman0 172.28.0.1/16'*) ;; *) f=$((f + 1)) ;; esac
    case "$ipout" in *'enp1s0 192.168.1.50/24'*) ;; *) f=$((f + 1)) ;; esac
    # and it must not drag the trailing junk in, or the line becomes unreadable at three interfaces
    case "$ipout" in *valid_lft* | *brd*) f=$((f + 1)) ;; esac
    case "$dead" in *'the guest did not answer'*) ;; *) f=$((f + 1)) ;; esac
    case "$alive" in *'the guest did not answer'*) f=$((f + 1)) ;; esac
    case "$alive" in *'address records'*) ;; *) f=$((f + 1)) ;; esac
    [ "$f" -eq 0 ] || {
        printf 'appliance-hostname-leg self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'appliance-hostname-leg self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    _hostname_self_test
fi
