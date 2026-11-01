#!/usr/bin/env bash
set -Eeuo pipefail

umask "${VERSION_PUBLISH_UMASK:-022}"
exec "$BASH" "$1/tests/go-parity/config_version_reference.sh" "$@"
