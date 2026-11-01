#!/usr/bin/env bash

_env_read_parity_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_env_read_root=$(cd -P "$_env_read_parity_dir/../.." && pwd -P)

# shellcheck source=/dev/null
source "$_env_read_root/tests/go-parity/env.sh"
# shellcheck source=/dev/null
source "$_env_read_root/lib/pithead/19b-go-env-read.sh"
unset _env_read_parity_dir _env_read_root
