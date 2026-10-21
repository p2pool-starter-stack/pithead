#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = --mounted ]; then
    shift
    scratch="$1" cli="$2" test_user="$3" parent_ns="$4"
    [ "$(id -u)" -eq 0 ]
    [ "$(readlink /proc/self/ns/mnt)" != "$parent_ns" ]
    mount --bind "$scratch/default" /etc/default
    mount --bind "$scratch/grub" /boot/grub
    exec runuser -u "$test_user" -- env TMPDIR="$scratch/tmp" bash "$0" --check "$scratch" "$cli" "$parent_ns"
fi

if [ "${1:-}" = --check ]; then
    shift
    scratch="$1" cli="$2" parent_ns="$3"
    [ "$(id -u)" -ne 0 ]
    [ "$(readlink /proc/self/ns/mnt)" != "$parent_ns" ]
    mountpoint -q /etc/default
    mountpoint -q /boot/grub
    # shellcheck disable=SC1090
    source "$cli"
    export PITHEAD_NR_HUGEPAGES_FILE="$scratch/nr_hugepages" PITHEAD_CMDLINE="$scratch/cmdline"
    export SKIP_OPTIMIZE=0
    sudo update-grub
    optimize_kernel
    check_entries() {
        python3 - /boot/grub/grub.cfg <<'PY'
import shlex
import sys

entries = []
host = False
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("### BEGIN "):
        host = line.strip() == "### BEGIN /etc/grub.d/10_linux ###"
    elif line.startswith("### END "):
        host = False
    elif host and line.split() and line.split()[0] in ("linux", "linuxefi", "linux16"):
        entries.append(shlex.split(line))
params = ("hugepagesz=2M", "hugepages=3072", "transparent_hugepage=never")
if not entries or any(any(row.count(param) != 1 for param in params) for row in entries):
    sys.exit("GRUB entries missing HugePages parameters exactly once")
if not any("console=tty1" in row and "console=ttyS0" in row for row in entries):
    sys.exit("GRUB entries missing cloud console arguments")
print(f"real grub-mkconfig: {len(entries)} host Linux entries carry HugePages parameters")
PY
    }
    check_entries
    cmp "$scratch/grub.before" /etc/default/grub
    cmp "$scratch/cloud.before" /etc/default/grub.d/50-cloudimg-settings.cfg
    cp /boot/grub/grub.cfg "$scratch/grub.first"
    cp /etc/default/grub.d/zz-pithead-hugepages.cfg "$scratch/dropin.first"
    optimize_kernel
    check_entries
    cmp "$scratch/grub.first" /boot/grub/grub.cfg
    cmp "$scratch/dropin.first" /etc/default/grub.d/zz-pithead-hugepages.cfg
    sudo rm /etc/default/grub.d/zz-pithead-hugepages.cfg
    sudo update-grub
    if check_entries >"$scratch/negative.log" 2>&1; then
        printf '%s\n' 'GRUB negative control unexpectedly passed' >&2
        exit 1
    fi
    grep -Fq 'GRUB entries missing HugePages' "$scratch/negative.log"
    printf '%s\n' 'real grub-mkconfig: idempotence, preserved user files and missing-drop-in control passed'
    exit 0
fi

cli="${1:-$HERE/../../../pithead}"
echo "== unit: real grub-mkconfig cloud precedence =="
if ! command -v grub-mkconfig >/dev/null; then
    [ "${CI:-false}" != true ] || {
        printf '%s\n' 'required grub-mkconfig is missing' >&2
        exit 1
    }
    printf '%s\n' 'SKIP: real grub-mkconfig unavailable (1 skipped)'
    exit 0
fi
[ "$(id -u)" -ne 0 ]
[ "$(uname -s)" = Linux ]
for tool in update-grub unshare mount mountpoint runuser python3 sudo; do
    command -v "$tool" >/dev/null
done
[ -r "$cli" ]
[ -d /boot/grub ]
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pithead-real-grub.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/default/grub.d" "$scratch/grub" "$scratch/tmp"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepage=never quiet splash"\nGRUB_DISABLE_OS_PROBER=true\n' >"$scratch/default/grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0"\n' >"$scratch/default/grub.d/50-cloudimg-settings.cfg"
cp "$scratch/default/grub" "$scratch/grub.before"
cp "$scratch/default/grub.d/50-cloudimg-settings.cfg" "$scratch/cloud.before"
printf '3072\n' >"$scratch/nr_hugepages"
printf 'console=tty1 console=ttyS0\n' >"$scratch/cmdline"
sudo unshare --mount --propagation private bash "$0" --mounted "$scratch" "$cli" "$(id -un)" "$(readlink /proc/self/ns/mnt)"
