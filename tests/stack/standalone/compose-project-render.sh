#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
default_project=$(env -i PATH="$PATH" HOME="${HOME:-}" docker compose --env-file "$1" -f "$ROOT/docker-compose.yml" --profile '*' config --format json) || exit 1
custom_project=$(env -i PATH="$PATH" HOME="${HOME:-}" COMPOSE_PROJECT_NAME=pithead-gate docker compose --env-file "$1" -f "$ROOT/docker-compose.yml" --profile '*' config --format json) || exit 1
jq -n --arg root "$ROOT" --argjson default "$default_project" --argjson custom "$custom_project" \
    '[$default, $custom] | walk(if type == "string" then split($root) | join("<workspace>") else . end)'
