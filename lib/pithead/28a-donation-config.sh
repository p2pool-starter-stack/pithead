validate_donation_config() {
    local key
    jq -e 'if has("donation") then .donation | type == "object" else true end' "$CONFIG_FILE" >/dev/null ||
        error "donation must be an object."
    for key in enabled tor; do
        jq -e --arg key "$key" 'if (.donation | type) == "object" and (.donation | has($key)) then .donation[$key] | type == "boolean" else true end' "$CONFIG_FILE" >/dev/null ||
            error "donation.$key must be a boolean."
    done
    jq -e 'if (.donation | type) == "object" and (.donation | has("percent")) then .donation.percent | type == "number" and . == floor and . >= 1 and . <= 10 else true end' "$CONFIG_FILE" >/dev/null ||
        error "donation.percent must be an integer 1–10 (percent); default 2."
}
