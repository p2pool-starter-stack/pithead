# shellcheck shell=bash
# Proof branch only: one real RC4 reset attempt after backup and Caddy polling.
# shellcheck disable=SC2154 # DASH_USER/DASH_PASS/ip are the provisioned phase's locals
: "${OS_RUN_SUITE:?source via the suite runner}"
_reset_repro_prepare() (
    local scratch archive
    scratch=$(mktemp -d) || return 1
    trap 'rm -rf "$scratch"' EXIT
    umask 077
    _ssh "cd /data/pithead && PITHEAD_BACKUP_PASSPHRASE='reset reproduction fixture' ./pithead backup -y" >"$scratch/backup.log" 2>&1 || {
        cat "$scratch/backup.log" >&2
        return 1
    }
    archive=$(_ssh "cd /data/pithead && ls -t backups/pithead-backup-*.tar.gz.enc | head -n1") || return 1
    # The selected name is constrained before it becomes a guest shell argument.
    [[ "$archive" =~ ^backups/pithead-backup-[A-Za-z0-9._-]+\.tar\.gz\.enc$ ]] || return 1
    _ssh "cd /data/pithead || exit 1; set -o pipefail; openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass pass:'reset reproduction fixture' -in '$archive' | tar -tz | grep -Fx data/pithead/config.json" >"$scratch/verify.log" 2>&1 || {
        cat "$scratch/verify.log" >&2
        return 1
    }
    printf 'RC4 reproduction: encrypted backup created and independently decrypted; waiting 300 seconds.\n' >&2
    sleep 300
    dashboard_curl -fsSk -m 5 "https://$ip/api/state" 2>/dev/null |
        jq -e 'type == "object"' >/dev/null
)
_reset_repro_poll() { # <scratch> <deadline>; no response body or credential enters the log
    local scratch="$1" deadline="$2" code crc json
    while [ "$(date +%s)" -lt "$deadline" ]; do
        crc=0 json=no
        rm -f "$scratch/state.json"
        code=$(dashboard_curl -sSk -m 1 -o "$scratch/state.json" -w '%{http_code}' "https://$ip/api/state" 2>/dev/null) || crc=$?
        jq -e 'type == "object"' "$scratch/state.json" >/dev/null 2>&1 && json=yes
        printf 'state-poll curl=%s HTTP=%s json=%s sampled_at=%s\n' "$crc" "${code:-none}" "$json" "$(date -u +%FT%TZ)"
        sleep 1
    done
}
_reset_repro_reboot_wait() (
    local scratch pid="" rc=0 count
    umask 077
    scratch=$(mktemp -d) || return 1
    trap '[ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }; rm -rf "$scratch"' EXIT
    _reset_repro_poll "$scratch" "$(($(date +%s) + 400))" >"$scratch/polls.log" &
    pid=$!
    sleep 30
    if ! count=$(grep -c '^state-poll curl=0 HTTP=200 json=yes sampled_at=' "$scratch/polls.log") ||
        [[ ! "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 2 ]; then
        printf 'RC4 reproduction: authenticated pre-reset Caddy state polls did not establish availability.\n' >&2
        cat "$scratch/polls.log" >&2
        return 1
    fi
    printf 'RC4 reproduction: 30 seconds of authenticated Caddy polls before the single reset.\n' >&2
    _reboot_wait "$@" || rc=$?
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
    cat "$scratch/polls.log" >&2
    return "$rc"
)
