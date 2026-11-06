#!/usr/bin/env bash
set -euo pipefail
cd /data/pithead
source ./pithead
_console() {
    printf '%s\n' "$@"
    case "$*" in
    *'Pithead is starting up — preparing the setup page.'*)
        [ ! -e config.json ] || error "Startup restore fixture already has a configuration."
        : >.wizard-startup-held
        local deadline=$((SECONDS + 300))
        while [ ! -e .wizard-startup-release ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 1; done
        [ -e .wizard-startup-release ] || error "Startup restore fixture timed out."
        ;;
    esac
}
firstboot_wizard
