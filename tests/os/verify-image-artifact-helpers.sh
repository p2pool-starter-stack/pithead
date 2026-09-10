# shellcheck shell=bash
# Sourced artifact-reference helpers for verify-image.sh and their focused self-tests.

# Write the compose file named by the image's COMPOSE_SOURCE stamp (#1215): the tree's copy for
# `tree`, the staged commit's copy for `tag NAME SHA`, or the shipped file after verifying its
# `file sha256:HASH` stamp. Missing or malformed stamps fail closed.
compose_reference() { # <image-root> <out-file>
    local kind tag sha extra trailing file
    {
        read -r kind tag sha extra || return 1
        if IFS= read -r trailing || [ -n "$trailing" ]; then return 1; fi
    } 2>/dev/null <"$1/opt/pithead/COMPOSE_SOURCE" || return 1
    case "$kind" in
    tree) [ -z "$tag$sha$extra" ] && cp ./docker-compose.yml "$2" || return 1 ;;
    tag) [ -n "$sha" ] && [ -z "$extra" ] && [ "$tag" = "v$(tr -d ' \t\r\n' <"$1/opt/pithead/VERSION")" ] && git show "$sha:docker-compose.yml" >"$2" 2>/dev/null || return 1 ;;
    file)
        file="${PITHEAD_OS_COMPOSE_FILE:-}"
        [[ "$tag" =~ ^sha256:[0-9a-f]{64}$ ]] && [ -z "$sha$extra" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
        cp "$file" "$2" || return 1
        [ "$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)" = "${tag#sha256:}" ] || {
            rm -f "$2"
            return 1
        }
        ;;
    *) return 1 ;;
    esac
}

# pithead-data-reset runs these behind `|| true`, so both must be baked into the image (#1069 W11).
data_reset_repair_tools_present() { # <image-root> — 0 iff both tools are executable
    local root="$1"
    { [ -x "$root/usr/sbin/e2fsck" ] || [ -x "$root/sbin/e2fsck" ]; } &&
        { [ -x "$root/usr/sbin/mkfs.ext4" ] || [ -x "$root/sbin/mkfs.ext4" ]; }
}

# Compare the final exact wizard implementation in a single-image `docker save` archive. The Python
# helper streams archive members without extracting paths and applies declared layers in order.
wizard_server_matches() { # <container-archive> <expected-server.py>
    local helper_dir
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$helper_dir/check-wizard-archive.py" "$1" "$2"
}
