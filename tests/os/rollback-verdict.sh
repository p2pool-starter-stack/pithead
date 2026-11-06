# shellcheck shell=bash

rollback_verdict_check() { # <os-update-state.json> <failing-check-substring>
    local state="$1" needle="$2"
    if ! printf '%s' "$state" | jq -e '.verdict.outcome == "rolled_back"' >/dev/null 2>&1; then
        printf 'verdict outcome is %s, not rolled_back' "$(printf '%s' "$state" | jq -r '.verdict.outcome // "absent"' 2>/dev/null || echo unreadable)"
        return 1
    fi
    if ! printf '%s' "$state" | jq -e '(.verdict.blocking // []) | map(select(type == "string" and length > 0)) | length > 0' >/dev/null 2>&1; then
        printf 'rolled_back verdict has an empty blocking list'
        return 1
    fi
    if ! printf '%s' "$state" | jq -e --arg n "$needle" '.verdict.blocking | any(type == "string" and contains($n))' >/dev/null 2>&1; then
        printf 'blocking does not name "%s": %s' "$needle" "$(printf '%s' "$state" | jq -c '.verdict.blocking' | cut -c1-200)"
        return 1
    fi
}

rollback_banner() { # <os-update-state.json> <repo-root>
    printf '%s' "$1" | jq -c '.verdict' | node --input-type=module -e '
const { verdictText } = await import(process.argv[1]);
let raw = "";
for await (const chunk of process.stdin) raw += chunk;
process.stdout.write(verdictText(JSON.parse(raw)) ?? "");
' "file://$2/dashboard/mining_dashboard/web/static/system/osverdict.mjs"
}

rollback_banner_blocked() { # <os-update-state.json> <repo-root>
    case "$(rollback_banner "$1" "$2")" in *"Blocked by: "?*) return 0 ;; *) return 1 ;; esac
}

rollback_evidence() { # <dest-prefix>
    local dest="$1"
    {
        echo "== verdict"
        _ssh "cat /data/pithead/data/control/results/os-update-state.json" 2>&1
        echo "== in-flight"
        _ssh "cat /data/pithead/data/os-update/in-flight.json" 2>&1
        echo "== grubenv"
        _ssh "grub-editenv /boot/efi/grub/grubenv list" 2>&1
        echo "== doctor"
        _ssh "pithead doctor --json" 2>&1
        echo "== pithead-boot journal (previous boot)"
        _ssh "journalctl -u pithead-boot -b -1 -o short-iso --no-pager" 2>&1
        echo "== pithead-boot journal (this boot)"
        _ssh "journalctl -u pithead-boot -b 0 -o short-iso --no-pager" 2>&1
    } >"$dest" 2>&1 || true
}
