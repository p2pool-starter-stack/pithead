#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=lib/pithead/19-small-utilities.sh
source "$ROOT/lib/pithead/19-small-utilities.sh"
WORK_BASE=${TMPDIR:-/tmp}
WORK=$(mktemp -d "${WORK_BASE%/}/pithead-dir-lines.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'echo "FAIL at line $LINENO"; cat "$WORK/reset.log" 2>/dev/null || true' ERR
mkdir -p "$WORK/bin" "$WORK/dashboard data" "$WORK/p2pool data"
cp "$ROOT/pithead" "$WORK/pithead"
cp "$ROOT/config.reference.json" "$WORK/config.json"
cat >"$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$SUDO_LOG"
STUB
cat >"$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
STUB
chmod +x "$WORK/bin/sudo" "$WORK/bin/docker"
export SUDO_LOG="$WORK/sudo.log" DOCKER_LOG="$WORK/docker.log"
export PATH="$WORK/bin:$PATH"
error() {
    printf '%s\n' "$1" >&2
    exit 1
}

write_env() {
    printf 'DEPLOYMENT_COMPLETED=true\nTOR_EGRESS_FIREWALL=false\n' >"$WORK/.env"
    printf 'DASHBOARD_DATA_DIR=%s\n' "$(dotenv_render_value "$1")" >>"$WORK/.env"
    printf 'P2POOL_DATA_DIR=%s\n' "$(dotenv_render_value "$2")" >>"$WORK/.env"
}

echo "== directory line breaks: real reset command refuses before mutation =="
for key in DASHBOARD_DATA_DIR P2POOL_DATA_DIR; do
    for ending in $'\n' $'\n\n' $'\r' $'\r\n' $'\nchild' $'\rchild'; do
        dashboard="$WORK/dashboard data"
        p2pool="$WORK/p2pool data"
        if [ "$key" = DASHBOARD_DATA_DIR ]; then dashboard+="$ending"; else p2pool+="$ending"; fi
        write_env "$dashboard" "$p2pool"
        : >"$SUDO_LOG"
        : >"$DOCKER_LOG"
        if "$WORK/pithead" reset-dashboard -y >"$WORK/reset.log" 2>&1; then
            echo "FAIL: reset accepted a line break in $key" >&2
            exit 1
        fi
        grep -q 'CR or LF' "$WORK/reset.log"
        [ ! -s "$SUDO_LOG" ]
        [ ! -s "$DOCKER_LOG" ]
    done
done

echo "== directory line breaks: every decoded directory key fails without output =="
for key in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR CONTROL_DIR CLEARNET_STATE_DIR CADDY_LOG_DIR PROXY_TLS_DIR PITHEAD_TLS_DIR; do
    printf '%s=%s\n' "$key" "$(dotenv_render_value "$WORK/data"$'\n')" >"$WORK/paths.env"
    if (env_get_file "$WORK/paths.env" "$key") >"$WORK/decoded" 2>"$WORK/error"; then
        echo "FAIL: decoder accepted a line break in $key" >&2
        exit 1
    fi
    [ ! -s "$WORK/decoded" ]
    grep -q 'CR or LF' "$WORK/error"
done
for value in "$WORK/data"$'\n' "$WORK/"$'\r'"data"; do
    if (assert_safe_dir "$value") >"$WORK/guard.log" 2>&1; then
        echo "FAIL: directory guard accepted a line break" >&2
        exit 1
    fi
done

echo "== directory line breaks: ordinary paths and other dotenv strings survive =="
write_env "$WORK/dashboard data" "$WORK/p2pool data"
: >"$SUDO_LOG"
: >"$DOCKER_LOG"
"$WORK/pithead" reset-dashboard -y >"$WORK/reset.log" 2>&1
python3 - "$SUDO_LOG" "$WORK" <<'PY'
import pathlib
import sys

calls = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")
for name in ("dashboard data", "p2pool data"):
    target = str(pathlib.Path(sys.argv[2]) / name).encode()
    assert any(calls[i:i + 3] == [b"rm", b"-rf", target] for i in range(len(calls)))
PY
literal=$'first\nsecond\r\n'
printf 'LITERAL=%s\n' "$(dotenv_render_value "$literal")" >"$WORK/literal.env"
actual=$(
    env_get_file "$WORK/literal.env" LITERAL
    printf '.'
)
[ "${actual%.}" = "$literal" ]
echo "PASS: directory line-break regression"
