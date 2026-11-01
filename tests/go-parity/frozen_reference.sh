#!/usr/bin/env bash
set -euo pipefail

port_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
port_base=$(mktemp -d "$port_root/.go-cache/frozen-reference.XXXXXX")
trap 'rm -rf "$port_base"' EXIT
git -C "$port_root" archive a73ffced33800de9435779a9cabef53864455acb | tar -x -C "$port_base"
make -C "$port_base" pithead

for port_tree in "$port_base" "$port_root"; do
    (
        cd "$port_tree"
        env -u PITHEAD_IMPL -u PITHEAD_GO_BINARY -u BASH_ENV \
            bash tests/integration/selftest/selftest-redact-vocab.sh
        env -u PITHEAD_IMPL -u PITHEAD_GO_BINARY -u BASH_ENV \
            bash tests/integration/selftest/selftest-bundle-redact-env.sh
        env -u PITHEAD_IMPL -u PITHEAD_GO_BINARY -u BASH_ENV \
            python3 tests/stack/lib/config-document-parser.py
    )
done
PITHEAD_PARITY_BASE="$port_base" python3 "$port_root/tests/go-parity/test_frozen_cli.py"
