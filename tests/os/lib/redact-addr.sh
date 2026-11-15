# shellcheck shell=bash
os_redact_addr() (
    # shellcheck source=lib/pithead/07-support-bundle.sh
    source "${BASH_SOURCE[0]%/*}/../../../lib/pithead/07-support-bundle.sh" &&
        sed -E \
            -e $'s/(\x1b\\[[0-9;]*[A-Za-z])/\\1\x01/g' \
            -e "s/\\('[1-9A-HJ-NP-Za-km-z]{1,12}…'/('[redacted-prefix]'/g" |
        bundle_redact_log |
            sed -E \
                -e 's/[1-9A-HJ-NP-Za-km-z]{85,}/[redacted-address]/g' \
                -e $'s/\x01//g'
)
