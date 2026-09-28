#!/usr/bin/env bash
# Package the verified raw appliance image and signed bundle for a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "$#" -ne 3 ]; then
    echo "usage: $0 IMAGE RAUCB OUTPUT_DIR" >&2
    exit 2
fi
image=$1 bundle=$2 out_dir=$3
[ -s "$image" ] && [ -s "$bundle" ] || {
    echo "image and bundle must be nonempty" >&2
    exit 2
}
version=$(tr -d '[:space:]' <VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "VERSION must be a release version" >&2
    exit 2
}

mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)
work_dir=$(mktemp -d "${TMPDIR:-$out_dir}/pithead-release.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
image_name="pithead-os-v${version}.img.xz"
bundle_name="pithead-os-v${version}.raucb"
bundle_bytes=$(wc -c <"$bundle")
if [ "$bundle_bytes" -ge 2147483648 ]; then
    echo "$bundle_name: $bundle_bytes bytes is at or above GitHub's 2 GiB asset limit" >&2
    exit 1
fi
xz -T0 -6 -c "$image" >"$work_dir/$image_name"
cp "$bundle" "$work_dir/$bundle_name"

# GitHub rejects assets at or above 2 GiB. Check the bytes that will be uploaded.
for name in "$image_name" "$bundle_name"; do
    bytes=$(wc -c <"$work_dir/$name")
    if [ "$bytes" -ge 2147483648 ]; then
        echo "$name: $bytes bytes is at or above GitHub's 2 GiB asset limit" >&2
        exit 1
    fi
    (cd "$work_dir" && sha256sum "$name" >"$name.sha256")
    echo "$name: $bytes bytes"
done

for name in "$image_name" "$bundle_name"; do
    mv "$work_dir/$name" "$work_dir/$name.sha256" "$out_dir/"
done
