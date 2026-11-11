validate_donation_config() {
    local key
    jq -e 'if has("donation") then .donation | type == "object" else true end' "$CONFIG_FILE" >/dev/null ||
        error "donation must be an object."
    for key in enabled tor; do
        jq -e --arg key "$key" 'if (.donation | type) == "object" and (.donation | has($key)) then .donation[$key] | type == "boolean" else true end' "$CONFIG_FILE" >/dev/null ||
            error "donation.$key must be a boolean."
    done
    jq -e 'if (.donation | type) == "object" then .donation | (if has("percent") then .percent else 0 end) as $p | (.enabled // false) as $on | ($p | type) == "number" and (($p >= 0.1 and $p <= 10) or ($p == 0 and ($on | not))) else true end' "$CONFIG_FILE" >/dev/null ||
        error "donation.percent must be a number from 0.1 to 10 (0 only while donation.enabled is false); default 0."
}
