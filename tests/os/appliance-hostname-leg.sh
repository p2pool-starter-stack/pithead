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
    bad "$context identity did not converge (${verdict:-unknown})"
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
