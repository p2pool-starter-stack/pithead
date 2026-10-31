#!/usr/bin/env bash

if [ "${PITHEAD_IMPL:-}" != bash ]; then
    _pithead_parity_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    _pithead_parity_root="$(cd -P "$_pithead_parity_dir/../.." && pwd -P)"
    export PITHEAD_IMPL=go
    export PITHEAD_GO_BINARY="$_pithead_parity_root/go/bin/pithead"
    unset _pithead_parity_dir _pithead_parity_root
fi
