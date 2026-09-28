#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

work_dir=$(mktemp -d "${TMPDIR:?}/pithead-package-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
printf 'bootable image bytes\n' >"$work_dir/system.img"
printf 'signed bundle bytes\n' >"$work_dir/update.raucb"
scripts/release/package-appliance.sh "$work_dir/system.img" "$work_dir/update.raucb" "$work_dir/assets"
version=$(tr -d '[:space:]' <VERSION)
image="pithead-os-v${version}.img.xz"
bundle="pithead-os-v${version}.raucb"
cmp "$work_dir/system.img" <(xz -dc "$work_dir/assets/$image")
cmp "$work_dir/update.raucb" "$work_dir/assets/$bundle"
(cd "$work_dir/assets" && sha256sum -c "$image.sha256" "$bundle.sha256")

truncate -s 2147483648 "$work_dir/update.raucb"
if scripts/release/package-appliance.sh "$work_dir/system.img" "$work_dir/update.raucb" "$work_dir/oversize" >"$work_dir/rejected.log" 2>&1; then
    echo "oversize bundle was accepted" >&2
    exit 1
fi
grep -q "at or above GitHub's 2 GiB asset limit" "$work_dir/rejected.log"
[ ! -e "$work_dir/oversize/$image" ] || {
    echo "partial release assets were published" >&2
    exit 1
}

mkdir "$work_dir/bin"
cat >"$work_dir/bin/xz" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import os; os.ftruncate(1, 2147483648)'
EOF
chmod +x "$work_dir/bin/xz"
if PATH="$work_dir/bin:$PATH" scripts/release/package-appliance.sh "$work_dir/system.img" "$work_dir/update.raucb" "$work_dir/oversize-image" >"$work_dir/rejected.log" 2>&1; then
    echo "oversize compressed image was accepted" >&2
    exit 1
fi
grep -q "at or above GitHub's 2 GiB asset limit" "$work_dir/rejected.log"
[ ! -e "$work_dir/oversize-image/$image" ] || {
    echo "partial release assets were published" >&2
    exit 1
}
echo "package-appliance: PASS"
