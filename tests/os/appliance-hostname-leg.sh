#!/usr/bin/env bash
# Hostname assertions for the provisioned appliance (#1957/#1966). Sourced by tests/os/run.sh;
# --self-test exercises the pure identity verdict without a guest.

hostname_identity_verdict() { # <label> <ip> <kernel> <env-host> <state-host> <cert-san> <avahi-state> <mdns-ip>
    local label="$1" ip="$2" kernel="$3" env_host="$4" state_host="$5" sans="$6" avahi="$7" mdns="$8"
    [ "$kernel" = "$label" ] || {
        printf 'kernel=%s' "${kernel:-empty}"
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
    printf 'ready'
}

# Every field the verdict short-circuits past, want beside got, so a failed row names all six
# rather than only the first one to disagree (#2060). The certificate SANs are squeezed onto the
# single line; an unread field reads `empty`, never as a gap in the line.
hostname_identity_payload() { # <label> <ip> <kernel> <env-host> <state-host> <cert-san> <avahi-state> <mdns-ip>
    printf 'want kernel=%s env=%s state=%s cert=DNS:%s+IP:%s avahi=active mdns=%s | got kernel=%s env=%s state=%s cert=%s avahi=%s mdns=%s' \
        "$1" "$1.local" "$1.local" "$1.local" "$2" "$2" \
        "${3:-empty}" "${4:-empty}" "${5:-empty}" \
        "$(printf '%s' "${6:-empty}" | tr -s '[:space:]' ' ')" "${7:-empty}" "${8:-empty}"
}

# What Avahi published and WHERE, read from the guest at the moment the row fails (#2060). The
# mDNS answers seen so far — 10.89.0.1 in one run, 172.28.0.1 in the next — are container-bridge
# addresses that move between runs, so the discriminator is the interface each address record was
# registered on, not the address. Avahi's own journal lines are the only place that pair appears
# ("Registering new address record for <addr> on <iface>.IPv4"), and the image ships no
# avahi-utils, so nothing here needs a package the appliance does not have.
hostname_mdns_evidence() { # <label>
    # _ssh's own default ceiling is 5400s. A row that already failed must not be able to spend
    # ninety minutes per probe collecting the evidence for its own failure. _ssh reads this
    # through Bash's dynamic scope.
    # shellcheck disable=SC2034
    local SSH_TIMEOUT=30
    printf '     --- mDNS evidence (#2060) ---\n'
    printf '     getent ahostsv4: %s\n' "$(_ssh "getent ahostsv4 '$1.local' 2>&1 | head -4" 2>/dev/null | tr -d '\r' | tr '\n' ';')"
    printf '     global v4 addresses: %s\n' "$(_ssh 'ip -4 -o addr show scope global' 2>/dev/null | tr -d '\r' | sed 's/  */ /g' | cut -d' ' -f2,4 | tr '\n' ' ')"
    printf '     default route: %s\n' "$(_ssh 'ip -4 route show default' 2>/dev/null | tr -d '\r' | tr '\n' ';')"
    printf '     avahi interface config: %s\n' "$(_ssh "grep -E '^[[:space:]]*(allow|deny)-interfaces|^[[:space:]]*use-ipv[46]' /etc/avahi/avahi-daemon.conf || echo 'no interface line — every interface'" 2>/dev/null | tr -d '\r' | tr '\n' ';')"
    printf '     avahi address records (address and interface, newest last):\n'
    # `grep .` turns an empty match into a sentence. Without it, "no lines matched" and "the guest
    # did not answer" both print as silence under the header, and the second is not evidence.
    _ssh "journalctl -u avahi-daemon.service -b --no-pager 2>/dev/null | grep -aE 'address record|relevant interface|Withdrawing' | tail -n 20 | grep . || echo 'no avahi address-record lines in this boot journal (or the guest did not answer)'" 2>/dev/null |
        tr -d '\r' | sed 's/^/     | /'
}

hostname_runtime_snapshot() { # <label>; one stable, comparable line
    local label="$1" kernel env_host state_host sans avahi mdns stamp
    kernel=$(_ssh 'hostname' 2>/dev/null | tr -d '\r')
    env_host=$(_ssh "sed -n 's/^HOST_IP=//p' /data/pithead/.env" 2>/dev/null | tr -d '\r')
    state_host=$(dashboard_curl -fsSk -m 8 "https://$ip/api/state" 2>/dev/null | jq -r '.host_ip // ""')
    sans=$(openssl s_client -connect "$ip:443" -servername "$label.local" </dev/null 2>/dev/null |
        openssl x509 -noout -ext subjectAltName 2>/dev/null | tr '\n' ' ')
    avahi=$(_ssh 'systemctl is-active avahi-daemon.service' 2>/dev/null | tr -d '\r')
    mdns=$(_ssh "getent ahostsv4 '$label.local' | awk 'NR == 1 {print \$1}'" 2>/dev/null | tr -d '\r')
    stamp=$(_ssh "systemctl show avahi-daemon.service -p ActiveEnterTimestampMonotonic --value" 2>/dev/null | tr -d '\r')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kernel" "$env_host" "$state_host" "$sans" "$avahi" "$mdns" "$stamp"
}

assert_appliance_hostname_identity() { # <label> <context> <dashboard-user> <dashboard-password>
    local label="$1" context="$2" tries=0 snap verdict=""
    # dashboard_curl reads these through Bash's dynamic scope.
    # shellcheck disable=SC2034
    local DASH_USER="$3" DASH_PASS="$4"
    while [ "$tries" -lt 12 ]; do
        snap=$(hostname_runtime_snapshot "$label")
        IFS=$'\t' read -r kernel env_host state_host sans avahi mdns _stamp <<<"$snap"
        verdict=$(hostname_identity_verdict "$label" "$ip" "$kernel" "$env_host" "$state_host" "$sans" "$avahi" "$mdns") && {
            ok "$context preserves kernel, rendered dashboard, certificate and mDNS identity"
            return 0
        }
        tries=$((tries + 1))
        sleep 5
    done
    hostname_mdns_evidence "$label"
    bad "$context identity did not converge (${verdict:-unknown}) — $(hostname_identity_payload "$label" "$ip" "$kernel" "$env_host" "$state_host" "$sans" "$avahi" "$mdns"); mDNS evidence above"
    return 1
}

phase_provision_hostname_regressions() { # <dashboard-user> <dashboard-password>
    local DASH_USER="$1" DASH_PASS="$2" before after live proposed preview
    assert_appliance_hostname_identity fixture-box "wizard hostname" "$DASH_USER" "$DASH_PASS" || return

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
    [ "$(hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.10)" = ready ] || f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 old fixture-box.local fixture-box.local "$good" active 192.0.2.10 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box.local fixture-box.local 'DNS:fixture-box.local' active 192.0.2.10 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box.local fixture-box.local 'DNS:fixture-box.local.evil, IP Address:192.0.2.100' active 192.0.2.10 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box.local fixture-box.local "$good" inactive 192.0.2.10 >/dev/null && f=$((f + 1))
    hostname_identity_verdict fixture-box 192.0.2.10 fixture-box fixture-box.local fixture-box.local "$good" active 192.0.2.11 >/dev/null && f=$((f + 1))
    # The payload the failing rows now carry. A verdict names ONE field; #2060's three rows needed
    # all of them, so assert both sides of the pair the verdict short-circuited on, and that an
    # unread field prints `empty` rather than collapsing the line.
    local payload
    payload=$(hostname_identity_payload fixture-box 192.0.2.10 fixture-box fixture-box.local fixture-box.local "$good" active 10.89.0.1)
    case "$payload" in *'mdns=192.0.2.10'*) ;; *) f=$((f + 1)) ;; esac
    case "$payload" in *'mdns=10.89.0.1'*) ;; *) f=$((f + 1)) ;; esac
    case "$payload" in *'cert=DNS:fixture-box.local+IP:192.0.2.10'*) ;; *) f=$((f + 1)) ;; esac
    payload=$(hostname_identity_payload fixture-box 192.0.2.10 "" "" "" "" "" "")
    case "$payload" in *'kernel=empty'*'cert=empty'*'avahi=empty'*'mdns=empty'*) ;; *) f=$((f + 1)) ;; esac
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
