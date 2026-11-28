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
_os_redact_source() {
    if [ -z "${BUNDLE_REDACT_SED+x}" ]; then
        # shellcheck source=lib/pithead/07a-redact-patterns.sh
        source "${BASH_SOURCE[0]%/*}/../../../lib/pithead/07a-redact-patterns.sh" || return 1
    fi
    # shellcheck source=lib/pithead/07-support-bundle.sh
    source "${BASH_SOURCE[0]%/*}/../../../lib/pithead/07-support-bundle.sh"
}
os_redact_addr() (
    _os_redact_source && _os_redact_addr_filter
)
# Per-line so a live stream is not held in pipe buffers; a final unterminated line is still emitted.
os_redact_addr_lines() (
    _os_redact_source || exit 1
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" | _os_redact_addr_filter
    done
)
