# shellcheck shell=bash
os_redact_addr() (
    # shellcheck source=lib/pithead/07-support-bundle.sh
    source "${BASH_SOURCE[0]%/*}/../../../lib/pithead/07-support-bundle.sh" && bundle_redact_log
)
