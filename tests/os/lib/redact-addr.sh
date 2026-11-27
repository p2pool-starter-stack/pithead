# shellcheck shell=bash
_os_redact_addr_filter() {
    sed -E \
        -e $'s/(\x1b\\[[0-9;]*[A-Za-z])/\\1\x01/g' \
        -e "s/\\('[1-9A-HJ-NP-Za-km-z]{1,12}…'/('[redacted-prefix]'/g" |
        bundle_redact_log |
        sed -E \
            -e 's/[1-9A-HJ-NP-Za-km-z]{85,}/[redacted-address]/g' \
            -e $'s/\x01//g'
}
os_redact_addr() (
    # shellcheck source=lib/pithead/07-support-bundle.sh
    source "${BASH_SOURCE[0]%/*}/../../../lib/pithead/07-support-bundle.sh" &&
        _os_redact_addr_filter
)
# Per-line so a live stream is not held in pipe buffers; a final unterminated line is still emitted.
os_redact_addr_lines() (
    # shellcheck source=lib/pithead/07-support-bundle.sh
    source "${BASH_SOURCE[0]%/*}/../../../lib/pithead/07-support-bundle.sh" || exit 1
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" | _os_redact_addr_filter
    done
)
