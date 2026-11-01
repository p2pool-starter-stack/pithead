#!/usr/bin/env bash

_compose_project_parity_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_compose_project_root=$(cd -P "$_compose_project_parity_dir/../.." && pwd -P)

export LC_ALL=C
export LANG=C
# shellcheck source=/dev/null
source "$_compose_project_root/tests/go-parity/env.sh"
# shellcheck source=/dev/null
source "$_compose_project_root/lib/pithead/19c-go-compose-project.sh"
unset _compose_project_parity_dir _compose_project_root
