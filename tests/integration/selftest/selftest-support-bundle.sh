#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== support-bundle archive and recovery failure controls =="
python3 "$HERE/test_support_bundle.py"
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-support-bundle.sh"

for fault in none no-rig rearm no-tmpdir fixture apply health inspect collect restore drift telegram-drift; do
    (
        IT_FAIL=0 IT_PASS=0 IT_PITHEAD=./pithead
        calls=0 applied=0 upped=0 waited=0 inspected=0 restored=0 rearmed=0 RIG_NAME=rig-fixture
        [ "$fault" != no-rig ] || RIG_NAME=
        export TMPDIR="${TMPDIR:-${HOME}}"
        sandbox=$(mktemp -d "$TMPDIR/bundle-selftest.XXXXXX")
        trap 'rm -rf "$sandbox"' EXIT
        mkdir "$sandbox/stack" "$sandbox/scratch"
        export TMPDIR="$sandbox/scratch"
        IT_REMOTE_DIR="$sandbox/stack"
        if [ "$fault" = no-tmpdir ]; then
            unset TMPDIR
            HOME="$sandbox/read-only-home"
        fi
        printf '{"p2pool":{"stratum_password":"auto"}}\n' >"$IT_REMOTE_DIR/config.json"
        printf 'PROXY_STRATUM_PASSWORD=original-auto-seed\n' >"$IT_REMOTE_DIR/.env"
        cat >"$IT_REMOTE_DIR/pithead" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$fault" <<'PRODUCER'
import io
import json
import os
import sys
import tarfile
from pathlib import Path
config = json.loads(Path("config.json").read_text())
for path in (("dashboard", "auth", "password"), ("p2pool", "stratum_password"), ("telegram", "bot_token")):
    value = config
    for key in path[:-1]:
        value = value[key]
    value[path[-1]] = {"__secret__": True}
files = {
    "host.txt": "host facts",
    "doctor.json": '{"checks":[{"status":"ok"}],"summary":{"ok":1}}',
    "doctor.txt": "Diagnostics summary",
    "config.masked.json": json.dumps(config),
    "env.redacted": "PROXY_STRATUM_PASSWORD=[redacted]\nTELEGRAM_BOT_TOKEN=[redacted]\nDASHBOARD_AUTH_HASH_B64=[redacted]\n",
    "compose-ps.txt": "dashboard running",
    "logs/dashboard.log": "service started",
}
if sys.argv[1] == "inspect":
    files["host.txt"] = ""
with tarfile.open("support-bundle-fixture.tar.gz", "w:gz") as archive:
    for name, value in files.items():
        content = value.encode()
        member = tarfile.TarInfo("bundle/" + name)
        member.size = len(content)
        archive.addfile(member, io.BytesIO(content))
if sys.argv[1] == "collect":
    sys.exit(1)
os.chmod("support-bundle-fixture.tar.gz", 0o600)
PRODUCER
STUB
        chmod +x "$IT_REMOTE_DIR/pithead"
        export fault
        rx() {
            if [[ "$1" == *'timeout 180'* ]]; then
                [ "${2:-}" = --stdin ] || return 1
                inspected=1
            elif [[ "$1" == 'cp -p '* ]]; then
                restored=1
            elif [[ "$1" == 'rm -f '* ]]; then
                printf '%s\n' "$1" >"$sandbox/cleanup"
            fi
            (cd "$IT_REMOTE_DIR" && bash -c "$1")
        }
        upgrade_secret_fingerprints() { grep '^PROXY_STRATUM_PASSWORD=' "$IT_REMOTE_DIR/.env" | openssl dgst -sha256; }
        push_config() {
            calls=$((calls + 1))
            printf '%s\n' "$1" >"$IT_REMOTE_DIR/config.json"
            [ "$fault" != fixture ]
        }
        pithead() {
            applied=$((applied + 1))
            if [ "$1" = up ]; then
                upped=$((upped + 1))
                return 0
            fi
            if [ "$restored" -eq 0 ]; then
                jq -r '
                    "PROXY_STRATUM_PASSWORD=" + .p2pool.stratum_password,
                    "TELEGRAM_BOT_TOKEN=" + .telegram.bot_token
                ' "$IT_REMOTE_DIR/config.json" >"$IT_REMOTE_DIR/.env"
                [ "$fault" != apply ]
            else
                [ "$fault" != drift ] || printf 'drift\n' >>"$IT_REMOTE_DIR/.env"
                [ "$fault" != telegram-drift ] || printf 'TELEGRAM_BOT_TOKEN=fixture-telegram-drift\n' >>"$IT_REMOTE_DIR/.env"
                [ "$fault" != restore ]
            fi
        }
        wait_status_ok() {
            waited=$((waited + 1))
            [ "$fault" != health ] || [ "$restored" -eq 1 ]
        }
        wait_borrow_rearm() {
            rearmed=$((rearmed + 1))
            [ "$fault" != rearm ] || {
                IT_FAIL=$((IT_FAIL + 1))
                return 1
            }
        }
        result=0
        run_support_bundle || result=$?
        [ "$restored" -eq 1 ] || exit 1
        [ "$applied" -ge 1 ] || exit 1
        [ ! -e "$IT_REMOTE_DIR/support-bundle-fixture.tar.gz" ] || exit 1
        [ -z "$(find "$sandbox/scratch" -mindepth 1 -print)" ] || exit 1
        if [ "$fault" = no-tmpdir ]; then
            snapshot=$(sed -n 's#^rm -f \(/tmp/support-bundle\.[^/]*\)/config\.json .*#\1#p' "$sandbox/cleanup")
            [ -n "$snapshot" ] && [ ! -e "$snapshot" ] || exit 1
        fi
        case "$fault" in
        none | no-rig | no-tmpdir)
            [ "$result" -eq 0 ] && [ "$inspected" -eq 1 ] && [ "$waited" -eq 2 ] || exit 1
            [ "$upped" -eq 1 ] || exit 1
            [ "$(cat "$IT_REMOTE_DIR/.env")" = 'PROXY_STRATUM_PASSWORD=original-auto-seed' ] || exit 1
            [ "$rearmed" -eq "$([ "$fault" = no-rig ] && echo 0 || echo 1)" ] || exit 1
            ;;
        rearm) [ "$result" -ne 0 ] && [ "$rearmed" -eq 1 ] ;;
        restore | drift | telegram-drift) [ "$result" -ne 0 ] && [ "$rearmed" -eq 0 ] ;;
        *) [ "$result" -ne 0 ] ;;
        esac
    ) || {
        echo "support-bundle failure control failed: $fault"
        exit 1
    }
done
