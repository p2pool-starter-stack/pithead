# shellcheck shell=bash
# Real equal-version A/B fallback after a migrating candidate fails its health gate.
preserve_migration_bundle() {
    local saved
    saved=$(mktemp "${TMPDIR:-$(dirname -- "$1")}/pithead-migration-good.XXXXXX.saved") || return 1
    cp "$1" "$saved" || {
        rm -f "$saved"
        return 1
    }
    printf '%s' "$saved"
}

phase_provision_same_version_fallback() {
    local version bundle floor state out rc
    version=$(tr -d '[:space:]' <VERSION)
    floor=$(_ssh "cat /data/pithead/.os-data-floor" | tr -d ' \r\n')
    bundle=$(PITHEAD_TEST_BREAK_HEALTHCHECK=1 PITHEAD_DATA_MIGRATION=true PITHEAD_MIN_OS_VERSION="$version" _build_bundle vmigfault) || {
        bundle_build_evidence
        bad "same-version migration fault bundle could not be built"
        return 1
    }
    _floor_stage "$bundle" || {
        bad "same-version migration fault bundle could not be staged"
        return 1
    }
    out=$(_floor_os_update)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        osupdate_failure_evidence "$rc" "$out"
        bad "same-version migration fault bundle could not be installed"
        return 1
    fi
    if ! _floor_fallback_wait vmigfault 1800; then
        bad "same-version migration did not fall back to the previous committed slot"
        return 1
    fi
    if _ssh "journalctl -u pithead-boot -b -1 | grep -q 'slot left uncommitted so A/B fallback stays armed'"; then
        ok "the equal-version migration candidate failed its ordinary commit gate"
    else
        bad "the equal-version candidate has no recorded commit-gate failure"
    fi
    state=$(_floor_state)
    if [ "$state" = "$floor||" ]; then
        ok "same-version fallback restored the data floor and consumed the owned migration marker"
    else
        bad "same-version fallback did not restore the migration marker and floor record"
    fi
    if _ssh "journalctl -u pithead-boot -b | grep -q 'holding chain services'"; then
        bad "the equal-version previous slot incorrectly held its chain services"
    else
        ok "the equal-version previous slot booted without a migration hold"
    fi
}
