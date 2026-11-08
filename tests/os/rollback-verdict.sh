# shellcheck shell=bash

rollback_blocking_check() {
    local json="$1" path="$2" needle="$3"
    [ "$path" = . ] && path=
    if ! printf '%s' "$json" | jq -e "($path.blocking // []) | map(select(type == \"string\" and length > 0)) | length > 0" >/dev/null 2>&1; then
        printf 'blocking list is empty or absent'
        return 1
    fi
    if ! printf '%s' "$json" | jq -e --arg n "$needle" "$path.blocking | any(type == \"string\" and contains(\$n))" >/dev/null 2>&1; then
        printf 'blocking does not name "%s": %s' "$needle" "$(printf '%s' "$json" | jq -c "$path.blocking" | cut -c1-200)"
        return 1
    fi
}

rollback_verdict_check() {
    if ! printf '%s' "$1" | jq -e '.verdict.outcome == "rolled_back"' >/dev/null 2>&1; then
        printf 'verdict outcome is %s, not rolled_back' "$(printf '%s' "$1" | jq -r '.verdict.outcome // "absent"' 2>/dev/null || echo unreadable)"
        return 1
    fi
    rollback_blocking_check "$1" .verdict "$2"
}

rollback_banner_served() {
    local deadline=$(($(date +%s) + ${3:-0}))
    while :; do
        curl -sSk -u "$2" -m 20 "https://$1/static/system/osverdict.mjs" 2>/dev/null | grep -qF 'Blocked by: ' && return 0
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 10
    done
}

rollback_evidence() {
    local dest="$1"
    {
        echo "== verdict"
        _ssh "cat /data/pithead/data/control/results/os-update-state.json" 2>&1
        echo "== in-flight"
        _ssh "cat /data/pithead/data/os-update/in-flight.json" 2>&1
        echo "== grubenv"
        _ssh "grub-editenv /boot/efi/grub/grubenv list" 2>&1
        echo "== doctor"
        _ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json" 2>&1
        echo "== pithead-boot journal (previous boot)"
        _ssh "journalctl -u pithead-boot -b -1 -o short-iso --no-pager" 2>&1
        echo "== pithead-boot journal (this boot)"
        _ssh "journalctl -u pithead-boot -b 0 -o short-iso --no-pager" 2>&1
    } >"$dest" 2>&1 || true
}
