#!/usr/bin/env bash
# Verify literal strings against Compose's real parser without starting a service.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$ROOT/tests/stack/lib.sh"
# shellcheck source=lib/pithead/19-small-utilities.sh
source "$ROOT/lib/pithead/19-small-utilities.sh"
echo "== unit: dotenv_render_value survives Compose's own parser =="
literal=$' single\'quote "double" \\path\\ $LABEL\t# text\nnext '
printf 'LITERAL=%s\n' "$(dotenv_render_value "$literal")" >"$SANDBOX/fixture.env"
printf '%s\n' '{"services":{"fixture":{"image":"fixture:local","environment":{"LITERAL":"${LITERAL}"}}}}' >"$SANDBOX/compose.json"
resolved="$(docker compose --env-file "$SANDBOX/fixture.env" -f "$SANDBOX/compose.json" config --format json)"
# config emits another Compose document, so literal dollar signs are escaped again.
expected="${literal//\$/\$\$}"
jq -e --arg expected "$expected" '.services.fixture.environment.LITERAL == $expected' <<<"$resolved" >/dev/null
echo "  ✓ Compose preserves literal dotenv strings"
