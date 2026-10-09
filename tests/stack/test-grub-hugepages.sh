# shellcheck shell=bash
: "${STACK_SUITE:?run tests/stack/run.sh}"
echo "== unit: persistent HugePages GRUB precedence =="
GR="$SANDBOX/grub"
mkdir -p "$GR/bin" "$GR/default/grub.d"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$GR/bin/sudo"
cat >"$GR/bin/update-grub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${GRUB_STUB_MODE:-}" != update-fail ] || exit 1
. "$PITHEAD_GRUB_DEFAULTS"
for cfg in "$PITHEAD_GRUB_DEFAULTS.d/"*.cfg; do
    [ ! -f "$cfg" ] || . "$cfg"
done
case "${GRUB_STUB_MODE:-}" in
    missing) GRUB_CMDLINE_LINUX=${GRUB_CMDLINE_LINUX/transparent_hugepage=never/} ;;
    empty) : >"$PITHEAD_GRUB_CONFIG"; exit 0 ;;
    conflict) GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX hugepages=1" ;;
    duplicate) GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX hugepages=3072" ;;
esac
printf '### BEGIN /etc/grub.d/10_linux ###\nlinux /vmlinuz root=UUID=fixture %s %s\nlinux /vmlinuz root=UUID=fixture recovery %s\n### END /etc/grub.d/10_linux ###\n' \
    "${GRUB_CMDLINE_LINUX:-}" "${GRUB_CMDLINE_LINUX_DEFAULT:-}" "${GRUB_CMDLINE_LINUX:-}" >"$PITHEAD_GRUB_CONFIG"
# Memory tests and foreign installations are not this host's kernel entries.
printf '### BEGIN /etc/grub.d/20_memtest86+ ###\nlinux16 /boot/memtest86+.bin\n### END /etc/grub.d/20_memtest86+ ###\n### BEGIN /etc/grub.d/30_os-prober ###\nlinux /other/vmlinuz root=UUID=other\n### END /etc/grub.d/30_os-prober ###\n' >>"$PITHEAD_GRUB_CONFIG"
if [ "${GRUB_STUB_MODE:-}" = no-host ]; then
    sed -i '/10_linux/,/END.*10_linux/d' "$PITHEAD_GRUB_CONFIG"
fi
STUB
chmod +x "$GR/bin/"*
run_grub() {
    PATH="$GR/bin:$PATH" PITHEAD_GRUB_DEFAULTS="$GR/default/grub" PITHEAD_GRUB_CONFIG="$GR/grub.cfg" \
        PITHEAD_NR_HUGEPAGES_FILE="$GR/nr_hugepages" PITHEAD_CMDLINE="$GR/cmdline" \
        bash -Eeuo pipefail -c '
            source "$1"
            SKIP_OPTIMIZE=0
            REBOOT_REQUIRED=${GRUB_INITIAL_REBOOT:-false}
            case "${GRUB_STUB_MODE:-}" in
                cat-fail) cat() { [ "$#" -gt 0 ] || return 1; command cat "$@"; } ;;
                printf-fail) printf() { case "$1" in GRUB_CMDLINE*) return 1 ;; esac; builtin printf "$@"; } ;;
                unavailable) command() { [ "$*" != "-v update-grub" ] || return 1; builtin command "$@"; } ;;
            esac
            rc=0
            "$2" "$PITHEAD_GRUB_DEFAULTS" || rc=$?
            echo "reboot_required=$REBOOT_REQUIRED"
            exit "$rc"
        ' _ "$STACK" "${1:-persist_grub_hugepages}"
}
printf '3072\n' >"$GR/nr_hugepages"
printf 'console=tty1 console=ttyS0\n' >"$GR/cmdline"
bp=$(run_sourced "$SANDBOX" randomx_boot_params)
assert_eq "valid HugePages and singular THP parameters" "$bp" "hugepagesz=2M hugepages=3072 transparent_hugepage=never"

# Cloud: a previous setup's flags in the main defaults are overridden by Ubuntu.
# Exercise the normal optimize_kernel path, not just the writer in isolation.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepages=never quiet splash"\n' >"$GR/default/grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0"\n' >"$GR/default/grub.d/50-cloudimg-settings.cfg"
before=$(cat "$GR/default/grub")
cloud_before=$(cat "$GR/default/grub.d/50-cloudimg-settings.cfg")
out=$(run_grub optimize_kernel 2>&1)
assert_rc "cloud: normal setup verifies persistence" "$?" 0
assert_contains "cloud: reboot required after verification" "$out" "reboot_required=true"
assert_eq "cloud: main defaults untouched" "$(cat "$GR/default/grub")" "$before"
assert_eq "cloud: user's drop-in untouched" "$(cat "$GR/default/grub.d/50-cloudimg-settings.cfg")" "$cloud_before"
assert_contains "cloud: effective consoles retained" "$(cat "$GR/grub.cfg")" "console=tty1 console=ttyS0"
for param in hugepagesz=2M hugepages=3072 transparent_hugepage=never; do
    assert_eq "cloud: $param once per generated entry" "$(awk -v p="$param" '$2=="/vmlinuz" { n=0; for(i=1;i<=NF;i++) if($i==p)n++; if(n!=1)bad=1 } END { print bad+0 }' "$GR/grub.cfg")" 0
done
# Before reboot, unchanged files still require the pending boot change.
out=$(run_grub optimize_kernel 2>&1)
assert_contains "cloud: pending reboot remains required" "$out" "reboot_required=true"
printf 'console=tty1 console=ttyS0 hugepagesz=2M hugepages=3072 transparent_hugepage=never\n' >"$GR/cmdline"
before=$(cat "$GR/default/grub.d/zz-pithead-hugepages.cfg" "$GR/grub.cfg")
out=$(run_grub optimize_kernel 2>&1)
assert_rc "cloud: second setup succeeds" "$?" 0
assert_contains "cloud: second setup needs no reboot" "$out" "reboot_required=false"
assert_contains "cloud: second setup reports verified state" "$out" "already configured and verified"
out=$(GRUB_INITIAL_REBOOT=true run_grub optimize_kernel 2>&1)
assert_rc "cloud: unchanged setup preserves other pending reboot" "$?" 0
assert_contains "cloud: other pending reboot remains required" "$out" "reboot_required=true"
assert_eq "cloud: second setup unchanged" "$(cat "$GR/default/grub.d/zz-pithead-hugepages.cfg" "$GR/grub.cfg")" "$before"
# An unreadable or conflicting running command line cannot establish that reboot finished.
for mode in conflict duplicate unreadable; do
    case "$mode" in
    conflict) printf 'hugepagesz=2M hugepages=1 transparent_hugepage=never\n' >"$GR/cmdline" ;;
    duplicate) printf 'hugepagesz=2M hugepages=3072 hugepages=3072 transparent_hugepage=never\n' >"$GR/cmdline" ;;
    unreadable) rm "$GR/cmdline" ;;
    esac
    out=$(run_grub optimize_kernel 2>&1)
    assert_rc "running $mode: setup verifies boot entries" "$?" 0
    assert_contains "running $mode: reboot remains required" "$out" "reboot_required=true"
done
printf 'console=tty1 console=ttyS0 hugepagesz=2M hugepages=3072 transparent_hugepage=never\n' >"$GR/cmdline"
# A generated-entry repair must still request reboot, even on a correctly booted host.
sed -i 's/hugepages=3072/hugepages=1/g' "$GR/grub.cfg"
out=$(run_grub optimize_kernel 2>&1)
assert_rc "cloud: generated-entry repair succeeds" "$?" 0
assert_contains "cloud: generated-entry repair requires reboot" "$out" "reboot_required=true"
# A changed managed drop-in must also retain the first-install reboot decision.
printf '# obsolete managed contents\n' >"$GR/default/grub.d/zz-pithead-hugepages.cfg"
out=$(run_grub optimize_kernel 2>&1)
assert_contains "cloud: drop-in repair requires reboot" "$out" "reboot_required=true"

# ISO: no drop-in directory, single-quoted defaults and other common arguments.
rm -rf "$GR/default/grub.d"
printf "GRUB_CMDLINE_LINUX='audit=1 hugepages=12'\nGRUB_CMDLINE_LINUX_DEFAULT='quiet splash transparent_hugepage=always'\n" >"$GR/default/grub"
before=$(cat "$GR/default/grub")
out=$(run_grub persist_grub_hugepages 2>&1)
assert_rc "ISO: setup works without existing drop-ins" "$?" 0
assert_contains "ISO: first install requires reboot" "$out" "reboot_required=true"
assert_eq "ISO: defaults untouched" "$(cat "$GR/default/grub")" "$before"
assert_contains "ISO: existing common arguments retained" "$(cat "$GR/grub.cfg")" "audit=1"
assert_contains "ISO: normal-entry defaults retained" "$(cat "$GR/grub.cfg")" "quiet splash"
assert_eq "ISO: competing old values removed from generated entries" "$(grep -Ec 'hugepages=12|transparent_hugepage=always' "$GR/grub.cfg")" 0

for mode in missing empty conflict duplicate no-host update-fail unavailable cat-fail printf-fail; do
    out=$(GRUB_STUB_MODE="$mode" run_grub optimize_kernel 2>&1)
    assert_rc "$mode: setup fails" "$?" 1
    assert_contains "$mode: actionable persistent failure" "$out" "Persistent HugePages setup failed"
    assert_contains "$mode: no reboot-success flag" "$out" "reboot_required=false"
done
# A later user override is never edited or silently accepted.
printf 'GRUB_CMDLINE_LINUX="audit=1"\n' >"$GR/default/grub.d/zzz-user.cfg"
out=$(run_grub optimize_kernel 2>&1)
assert_rc "later override: setup refuses unverified persistence" "$?" 1
assert_contains "later override: diagnostic names drop-ins" "$out" "Check later GRUB drop-ins"
assert_eq "later override: user's file untouched" "$(cat "$GR/default/grub.d/zzz-user.cfg")" 'GRUB_CMDLINE_LINUX="audit=1"'
rm -rf "$GR/default/grub.d"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$GR/default/grub"
out=$(run_grub optimize_kernel </dev/null 2>&1)
assert_rc "headless fresh setup: remains boot-only" "$?" 0
assert_contains "headless fresh setup: explicit skip" "$out" "No terminal attached"
assert_eq "headless fresh setup: no persistent drop-in written" "$([ -d "$GR/default/grub.d" ] && echo yes || echo no)" no

# A user's unrelated reservation does not authorize a new 6 GiB reservation.
printf 'GRUB_CMDLINE_LINUX="audit=1 hugepages=12"\n' >"$GR/default/grub"
before=$(cat "$GR/default/grub")
out=$(run_grub optimize_kernel </dev/null 2>&1)
assert_rc "manual reservation: headless setup skips persistence" "$?" 0
assert_contains "manual reservation: confirmation still required" "$out" "No terminal attached"
assert_eq "manual reservation: main defaults unchanged" "$(cat "$GR/default/grub")" "$before"
assert_eq "manual reservation: no drop-in written" "$([ -d "$GR/default/grub.d" ] && echo yes || echo no)" no

# A typo outside the recognizable Pithead triplet is not consent to a new reservation.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet hugepagesz=2M hugepages=3072 transparent_hugepages=never"\n' >"$GR/default/grub"
before=$(cat "$GR/default/grub")
out=$(run_grub optimize_kernel </dev/null 2>&1)
assert_rc "unrecognized typo: headless setup skips persistence" "$?" 0
assert_contains "unrecognized typo: confirmation required" "$out" "No terminal attached"
assert_eq "unrecognized typo: defaults unchanged" "$(cat "$GR/default/grub")" "$before"
out=$(run_grub persist_grub_hugepages 2>&1)
assert_rc "unrecognized typo: consented persistence verifies" "$?" 0
assert_not_contains "unrecognized typo: generated entries remove plural parameter" "$(cat "$GR/grub.cfg")" 'transparent_hugepages='
assert_contains "unrecognized typo: consented install requires reboot" "$out" 'reboot_required=true'

# Parameter-like words inside quoted values must survive both filtering and verification.
cat >"$GR/default/grub" <<'DEFAULTS'
GRUB_CMDLINE_LINUX='audit=1 example="keep hugepages=12 tail" hugepages="12"'
GRUB_CMDLINE_LINUX_DEFAULT='quiet label="transparent_hugepage=always hugepagesz=1G"'
DEFAULTS
out=$(run_grub persist_grub_hugepages 2>&1)
assert_rc "quoted values: persistence verifies" "$?" 0
assert_contains "quoted values: embedded reservation preserved" "$(cat "$GR/grub.cfg")" 'example="keep hugepages=12 tail"'
assert_contains "quoted values: embedded THP and size preserved" "$(cat "$GR/grub.cfg")" 'label="transparent_hugepage=always hugepagesz=1G"'
assert_not_contains "quoted values: actual old reservation removed" "$(cat "$GR/grub.cfg")" 'hugepages="12"'
