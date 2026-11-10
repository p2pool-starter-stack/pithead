# shellcheck shell=bash
DIY_PASS=0
DIY_FAIL=0
DIY_MISSING=0

diy_redact() {
    grep -viE 'pass(word|wd)?|secret|token|login|username|view.?key' |
        sed -E 's/[A-Za-z0-9]{90,}/<redacted-address>/g'
}

diy_pass() {
    DIY_PASS=$((DIY_PASS + 1))
    printf 'LIFECYCLE-STEP %s PASS %s\n' "$1" "${2:-}"
}

diy_fail() {
    DIY_FAIL=$((DIY_FAIL + 1))
    printf 'LIFECYCLE-STEP %s FAIL %s\n' "$1" "${2:-}"
}

diy_missing() {
    DIY_MISSING=$((DIY_MISSING + 1))
    printf 'LIFECYCLE-STEP %s MISSING %s\n' "$1" "${2:-}"
}

diy_summary() {
    printf 'LIFECYCLE-SUMMARY pass=%s fail=%s missing=%s\n' "$DIY_PASS" "$DIY_FAIL" "$DIY_MISSING"
    [ "$DIY_FAIL" -eq 0 ]
}

diy_run() {
    local id=$1 rc=0
    shift
    mkdir -p "$DIY_LOG_DIR"
    "$@" >"$DIY_LOG_DIR/$id.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -n 30 "$DIY_LOG_DIR/$id.log" | diy_redact
    fi
    return "$rc"
}

diy_previous_tag() {
    local version=${1%%-*} tag
    while read -r tag; do
        tag=${tag##*/}
        [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        printf '%s\n' "${tag#v}"
    done | {
        printf '%s\n' "$version"
        cat
    } | sort -uV | awk -v v="$version" '$0 == v { print last; exit } { last = $0 }' | sed '/^$/d; s/^/v/'
}

diy_other_pool() {
    case "$(jq -r '.p2pool.pool // "mini"' "$1")" in
    nano) printf 'mini\n' ;;
    *) printf 'nano\n' ;;
    esac
}

diy_secret_fingerprint() {
    grep -E '(PASSWORD|TOKEN|SECRET)[A-Z_]*=' "$1" | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

diy_tree_digest() {
    local path
    for path in "$@"; do
        [ -e "$path" ] || continue
        find "$path" -xdev \( -type f -o -type l -o -type d \) -printf '%p\t%y\t%m\t%s\n' | LC_ALL=C sort
        find "$path" -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    done | sha256sum | cut -d' ' -f1
}

diy_residue_scan() {
    local line
    systemctl list-units --all --plain --no-legend 'pithead-*' 2>/dev/null |
        while read -r line; do printf 'unit record: %s\n' "$line"; done
    systemctl list-unit-files --plain --no-legend 'pithead-*' 2>/dev/null |
        while read -r line; do printf 'unit file: %s\n' "$line"; done
    systemctl --failed --plain --no-legend 2>/dev/null | grep -i pithead |
        while read -r line; do printf 'failed unit: %s\n' "$line"; done
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null |
            while read -r line; do printf 'container: %s\n' "$line"; done
        docker volume ls -q 2>/dev/null |
            while read -r line; do printf 'volume: %s\n' "$line"; done
        if [ -s "$DIY_STATE_DIR/images.txt" ]; then
            docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fxf "$DIY_STATE_DIR/images.txt" |
                while read -r line; do printf 'image: %s\n' "$line"; done
        fi
    fi
    iptables -S DOCKER-USER 2>/dev/null | grep -E 'pithead-(tor-egress|lan-guard)' |
        while read -r line; do printf 'iptables rule: %s\n' "$line"; done
    nft list tables 2>/dev/null | grep -E 'pithead_(egress|lan)' |
        while read -r line; do printf 'nft table: %s\n' "$line"; done
    return 0
}

diy_assert_residue_class() {
    local id=$1 pattern=$2 pass_detail=$3 findings
    findings=$(diy_residue_scan | grep -E "$pattern")
    if [ -z "$findings" ]; then
        diy_pass "$id" "$pass_detail"
    else
        diy_fail "$id" "$(printf '%s' "$findings" | head -n 8 | tr '\n' ';')"
    fi
}

diy_assert_no_residue() {
    local prefix=$1
    diy_assert_residue_class "$prefix-systemd" '^(unit record|unit file|failed unit):' \
        "no Pithead unit files, active or failed unit records"
    diy_assert_residue_class "$prefix-containers-firewall" '^(container|volume|image|iptables rule|nft table):' \
        "no containers, volumes, images or firewall rules"
}

diy_step() {
    local id=$1 detail=$2
    shift 2
    if diy_run "$id" "$@"; then
        diy_pass "$id" "$detail"
    else
        diy_fail "$id" "$detail"
        return 1
    fi
}
