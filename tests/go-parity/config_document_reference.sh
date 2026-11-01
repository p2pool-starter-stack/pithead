#!/usr/bin/env bash
set -Eeuo pipefail

export PITHEAD_IMPL=bash
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER
# shellcheck source=/dev/null
source "$1/lib/pithead/22a-config-document.sh"
config_document_error "$2" "$3"
