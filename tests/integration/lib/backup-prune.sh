# shellcheck shell=bash
# shellcheck disable=SC2016

BACKUP_PRUNE_SCRIPT='
d=$1; keep=$2; shift 2
markers="$d/.pithead-e2e-safety"
[ ! -L "$markers" ] || exit 1
mkdir -m 700 -p -- "$markers" || exit 1
current=${1:-}
case "$current" in pithead-backup-????????-??????.tar.gz) ;; *) exit 1 ;; esac
[ -f "$d/$current" ] && [ ! -L "$d/$current" ] || exit 1
[ ! -L "$markers/$current" ] || exit 1
: >"$markers/$current" || exit 1
[ "$keep" -gt 0 ] || exit 0
n=0; i=0
for f in $(ls -1 "$d" 2>/dev/null | grep -E "^pithead-backup-[0-9]{8}-[0-9]{6}\.tar\.gz\$" | sort -r); do
    [ -f "$d/$f" ] && [ ! -L "$d/$f" ] || continue
    [ -f "$markers/$f" ] && [ ! -L "$markers/$f" ] || continue
    i=$((i + 1))
    [ "$i" -gt "$keep" ] || continue
    skip=0
    for p in "$@"; do [ "$f" != "$p" ] || skip=1; done
    [ "$skip" -eq 0 ] || continue
    rm -f -- "$d/$f" && { rm -f -- "$markers/$f"; n=$((n + 1)); }
done
echo "pruned $n old safety backup(s) from $d (kept the newest $keep)"
'

backup_prune_cmd() {
    local keep="${PITHEAD_E2E_BACKUP_KEEP:-10}" dir="$1" a args=()
    shift
    case "$keep" in '' | *[!0-9]*) keep=10 ;; esac
    for a in "$@"; do [ -z "$a" ] || args+=("$(basename "$a")"); done
    printf 'bash -c %q _ %q %q' "$BACKUP_PRUNE_SCRIPT" "$dir" "$keep"
    for a in ${args[@]+"${args[@]}"}; do printf ' %q' "$a"; done
}

backup_prune() {
    local run="$1" cmd
    shift
    cmd="$(backup_prune_cmd "$@")"
    [ -z "$cmd" ] || "$run" "$cmd" || echo "safety backup pruning skipped (not fatal)"
}
