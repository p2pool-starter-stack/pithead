# shellcheck shell=bash
# Shared by tests/os/phases/image-upgrade.sh and tests/os/image-upgrade-bundle.sh, which run in
# separate processes and so can't share a sourced function any other way.
image_upgrade_input_failure() { # <sub-step> <redacted-command> <exit-status>
    printf 'image-upgrade input failure: sub-step=%s command="%s" exit=%s\n' "$1" "$2" "$3" >&2
    return "$3"
}
