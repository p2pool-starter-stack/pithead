#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ref=$(sed -nE 's#^FROM (ghcr\.io/sigstore/cosign/cosign):[A-Za-z0-9._-]+@(sha256:[0-9a-f]{64})$#\1@\2#p' "$root/build/cosign/Dockerfile" 2>/dev/null) || ref=""
[ "$(printf '%s\n' "$ref" | grep -c .)" = 1 ] || {
    echo "cosign-image: $root/build/cosign/Dockerfile needs exactly one 'FROM ghcr.io/sigstore/cosign/cosign:<tag>@sha256:<digest>' line" >&2
    exit 1
}
printf '%s\n' "$ref"
