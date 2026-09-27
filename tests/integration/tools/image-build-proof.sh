#!/usr/bin/env bash
# Fingerprint the effective, supported Compose build inputs for the shared Monero image.
# A proof is deliberately unavailable if Compose adds a feature this script cannot account for.
set -euo pipefail
[ "$#" -eq 2 ] || exit 1
root=$1 service=$2
case "$service" in monerod | wallet-rpc) ;; *) exit 1 ;; esac
cd "$root"
root=$(pwd -P)
context=$root/build/monero
[ -d "$context" ] && [ ! -e "$context/.dockerignore" ] || exit 1
[ -z "$(find "$context" ! -type f ! -type d -print -quit)" ] || exit 1
spec=$(docker compose config --format json | jq -ce --arg s "$service" --arg c "$context" '
  .services[$s] as $svc
  | select($svc.image == .services.monerod.image and $svc.image == .services["wallet-rpc"].image)
  | select(.services.monerod.build == .services["wallet-rpc"].build)
  | $svc.build
  | select(type == "object" and ((keys - ["args", "context", "dockerfile"]) | length) == 0)
  | select(.context == $c and ((.dockerfile // "Dockerfile") == "Dockerfile"))
  | select((.args // {}) | type == "object")
  | (.args // {})
' | jq -cS .)
[ -n "$spec" ] || exit 1
# Dockerfile instructions are case-insensitive. Only the current single-stage, digest-pinned
# grammar is supported; COPY --from or remote ADD would introduce an unmeasured image/input.
if grep -Eiq '^[[:space:]]*ADD[[:space:]]|--from=|--mount=' "$context/Dockerfile"; then
    exit 1
fi
base=$(awk 'toupper($1) == "FROM" {print $2}' "$context/Dockerfile")
[ "$(printf '%s\n' "$base" | wc -l)" -eq 1 ] || exit 1
printf '%s\n' "$base" | grep -Eq '@sha256:[0-9a-f]{64}$' || exit 1
context_hash=$(tar -C "$context" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - . | sha256sum | cut -d' ' -f1)
printf '%s\n%s\n%s\n' "$base" "$spec" "$context_hash" | sha256sum | cut -d' ' -f1
