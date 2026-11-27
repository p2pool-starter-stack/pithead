# shellcheck shell=bash
# shellcheck disable=SC2154 # ip is the guest lease supplied by the harness.
# Plain-port probes run on the harness host, outside the guest's container network.
redirect_location_matches() {
    local headers="$1" target="$2" status="$3" location
    location=$(printf '%s\n' "$headers" | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}')
    [[ "$headers" == HTTP/*" $status "* ]] && [ "$location" = "$target" ]
}

wizard_redirect_probe() {
    local host="$1" headers page
    headers=$(curl --noproxy '*' -sS -m 10 -D - -o /dev/null \
        --resolve "$host:80:$ip" "http://$host/" 2>/dev/null) || return 1
    redirect_location_matches "$headers" "https://$host/" 301 || return 1
    # Follow the real plain-port redirect and prove it lands on the setup page, not merely TLS.
    page=$(curl --noproxy '*' -fsSkL -m 15 --max-redirs 1 \
        --resolve "$host:80:$ip" --resolve "$host:443:$ip" \
        -w '\n%{http_code}' "http://$host/" 2>/dev/null) || return 1
    [[ "$page" == *"Pithead setup"* && "$page" == *$'\n200' ]]
}

phase_wizard_redirect() {
    local bridge headers
    if wizard_redirect_probe "$ip"; then
        ok "wizard plain LAN URL redirects to the same LAN address and follows to setup HTTP 200 (#3234)"
    else
        bad "wizard plain LAN URL did not redirect to the same address and setup HTTP 200 (#3234)"
    fi
    # Explicit resolution exercises the documented name even when the harness lacks mDNS.
    if wizard_redirect_probe pithead.local; then
        ok "wizard plain mDNS host redirects to the same name and follows to setup HTTP 200 (#3234)"
    else
        bad "wizard plain mDNS host did not redirect to the same name and setup HTTP 200 (#3234)"
    fi
    bridge=$(_ssh "podman inspect pithead-wizard | jq -r '.[0].NetworkSettings.Networks[].IPAddress'" 2>/dev/null) || bridge=""
    if [ -z "$bridge" ]; then
        bad "wizard bridge inventory unavailable for hostile Host probe (#3234)"
        return
    fi
    for bridge in $bridge evil.example; do
        headers=$(curl --noproxy '*' -sS -m 10 -D - -o /dev/null \
            -H "Host: $bridge" "http://$ip/" 2>/dev/null) || headers=""
        if redirect_location_matches "$headers" "https://$ip/" 301; then
            ok "wizard unknown or bridge Host falls back to the guest LAN address (#3234)"
        else
            bad "wizard unknown or bridge Host did not fall back to the guest LAN address (#3234)"
        fi
    done
}

phase_dashboard_redirect() {
    local headers
    headers=$(curl --noproxy '*' -sS -m 10 -D - -o /dev/null "http://$ip/" 2>/dev/null) || headers=""
    if redirect_location_matches "$headers" "https://$ip/" 308; then
        ok "provisioned Caddy plain LAN URL keeps the typed LAN address (#3234)"
    else
        bad "provisioned Caddy plain LAN URL did not keep the typed LAN address (#3234)"
    fi
}
