#!/usr/bin/env bash
# Exercise final-filesystem wizard verification without Docker or a running container.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/verify-image-artifact-helpers.sh
source "$HERE/../../os/verify-image-artifact-helpers.sh"
echo "== verify-image: wizard package archive matches the checkout =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'current wizard\n' >"$TMP/expected.py"

python3 - "$TMP" <<'PY'
import io, json, sys, tarfile
from pathlib import Path

root = Path(sys.argv[1])
target = "app/mining_dashboard/wizard/server.py"

def layer(entries):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as tar:
        for name, content, kind in entries:
            info = tarfile.TarInfo(name)
            if kind == "file":
                body = content.encode(); info.size = len(body)
                tar.addfile(info, io.BytesIO(body))
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE; info.linkname = content; tar.addfile(info)
            else:
                raise ValueError(kind)
    return data.getvalue()

current = layer([(target, "current wizard\n", "file")])
stale = layer([(target, "stale wizard\n", "file")])
decoy = layer([("tmp/decoy/app/mining_dashboard/wizard/server.py", "current wizard\n", "file")])
whiteout = layer([("app/mining_dashboard/wizard/.wh.server.py", "", "file")])
ancestor_link = layer([("app/mining_dashboard/wizard", "elsewhere", "symlink")])
legacy = layer([(target, "current wizard\n", "file")])

def image(name, declared, members, manifest=None):
    manifest = manifest if manifest is not None else [{"Config":"config.json","RepoTags":["pithead:test"],"Layers":declared}]
    with tarfile.open(root / name, "w:gz") as tar:
        # Deliberately permit outer order to differ from declared layer order.
        for member_name, body in members:
            info = tarfile.TarInfo(member_name); info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
        encoded = json.dumps(manifest).encode()
        info = tarfile.TarInfo("manifest.json"); info.size = len(encoded)
        tar.addfile(info, io.BytesIO(encoded))

image("valid.tar.gz", ["blobs/sha256/current"], [("blobs/sha256/current", current)])
image("stale.tar.gz", ["blobs/sha256/stale"], [("blobs/sha256/stale", stale)])
image("decoy.tar.gz", ["blobs/sha256/decoy"], [("blobs/sha256/decoy", decoy)])
image("later-stale.tar.gz", ["blobs/sha256/current", "blobs/sha256/stale"], [("blobs/sha256/current", current), ("blobs/sha256/stale", stale)])
image("layer-order.tar.gz", ["blobs/sha256/stale", "blobs/sha256/current"], [("blobs/sha256/current", current), ("blobs/sha256/stale", stale)])
image("whiteout.tar.gz", ["blobs/sha256/current", "blobs/sha256/whiteout"], [("blobs/sha256/current", current), ("blobs/sha256/whiteout", whiteout)])
image("ancestor-link.tar.gz", ["blobs/sha256/current", "blobs/sha256/link"], [("blobs/sha256/current", current), ("blobs/sha256/link", ancestor_link)])
image("legacy.tar.gz", ["abc/layer.tar"], [("abc/layer.tar", legacy)])
image("missing-layer.tar.gz", ["blobs/sha256/absent"], [])
image("ambiguous.tar.gz", [], [], manifest=[{"Layers":["blobs/sha256/a"]},{"Layers":["blobs/sha256/b"]}])
with tarfile.open(root / "malformed-manifest.tar.gz", "w:gz") as tar:
    info = tarfile.TarInfo("manifest.json"); info.size = 1
    tar.addfile(info, io.BytesIO(b"{"))
(root / "corrupt.tar.gz").write_text("not a tar archive\n")
PY

check() {
    local name="$1" want="$2" source="${3:-$TMP/expected.py}" rc=0
    wizard_server_matches "$TMP/$name.tar.gz" "$source" >"$TMP/result" || rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "FAIL: $name (expected $want, got $rc)"
        cat "$TMP/result"
        exit 1
    fi
    echo "PASS: $name"
}

check valid 0
check legacy 0
check stale 1
check decoy 1
check later-stale 1
check layer-order 0
check whiteout 1
check ancestor-link 1
check missing-layer 1
check ambiguous 1
check malformed-manifest 1
check corrupt 1
check valid 1 "$TMP/missing-source.py"
