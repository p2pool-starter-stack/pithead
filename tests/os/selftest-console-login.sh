#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$HERE/console-login-probe.py" <<'PY'
import copy
import ctypes
import importlib.util
import sys
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
good = {
    "config": {"dashboard": {"auth": {"password": "new-password"}}},
    "shadow": "root:$fixture$new:20000:0:99999:7:::",
    "status": "root P 2026-01-01 0 99999 7 -1",
    "mount": {"target": "/etc", "fstype": "overlay", "options": "rw,lowerdir=/etc,upperdir=/run/pithead-etc/upper,workdir=/run/pithead-etc/work"},
    "backing": "tmpfs",
    "matches": lambda password, hashed: password == "new-password" and hashed == "$fixture$new",
}
assert probe.console_login_valid(**good)
for field, value in (
    ("config", {}), ("shadow", ""), ("shadow", "root:!:20000:0:99999:7:::"),
    ("shadow", "root:$fixture$old:20000:0:99999:7:::"),
    ("shadow", good["shadow"] + "\n" + good["shadow"]),
    ("status", "root L"), ("status", "root NP"), ("status", ""),
    ("backing", "ext4"), ("backing", ""),
):
    case = copy.deepcopy(good)
    case[field] = value
    assert not probe.console_login_valid(**case), field
for field, value in (
    ("target", "/"), ("fstype", "ext4"), ("options", "rw"),
    ("options", "upperdir=/data/pithead-etc/upper"),
    ("options", "upperdir=/run/../data/upper"),
    ("options", "upperdir=/runtime/upper"),
):
    case = copy.deepcopy(good)
    case["mount"][field] = value
    assert not probe.console_login_valid(**case), field
for result, expected in ((b"$fixture$new", True), (b"$fixture$old", False), (None, False), (b"*0", False)):
    crypt = Mock(return_value=result)
    with patch.object(ctypes, "CDLL", return_value=Mock(crypt=crypt)):
        assert probe.password_matches("new-password", "$fixture$new") == expected
    crypt.assert_called_once_with(b"new-password", b"$fixture$new")
with patch("builtins.open", side_effect=OSError):
    assert probe.main() == 1
print("PASS: console hash parity, password status, volatile upperdir and fail-closed reads")
PY

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/pithead/26-appliance-tls-provisioning.sh
source "$HERE/../../lib/pithead/26-appliance-tls-provisioning.sh"
# shellcheck source=lib/pithead/38-setup-command.sh
source "$HERE/../../lib/pithead/38-setup-command.sh"
CONFIG_FILE="$work/config.json" REBOOT_REQUIRED=false appliance=true
mkdir "$work/bin"
printf '#!/usr/bin/env bash\nexit 99\n' >"$work/bin/chpasswd"
chmod +x "$work/bin/chpasswd"
PATH="$work/bin:$PATH"
is_deployed() { return 1; }
is_appliance() { [ "$appliance" = true ]; }
mutation_lock_acquire() { :; }
mutation_lock_release() { printf 'unlock\n' >>"$work/trace"; }
check_prerequisites() { :; }
ensure_config_exists() { :; }
ensure_onion_password() { :; }
parse_and_validate_config() { :; }
preflight_resources() { :; }
check_stratum_exposure() { :; }
load_preserved_state() { :; }
resolve_dashboard_host() { :; }
reconcile_appliance_hostname() { :; }
prepare_directories() { :; }
render_env() { :; }
provision_tor() { :; }
inject_service_configs() { :; }
optimize_kernel() { :; }
generate_caddyfile() { printf 'caddy\n' >>"$work/trace"; }
provision_control_runner() { :; }
provision_egress_check_units() { :; }
provision_lan_guard_check_units() { :; }
render_local_miner_config() { :; }
update_current_symlink() { :; }
announce_dashboard_url() { :; }
prompt_start_stack() { :; }
provision_local_miner() { :; }
ensure_etc_overlay() { printf 'etc\n' >>"$work/trace"; }
log() { :; }
sudo() {
    case "$1" in
    chpasswd)
        cat >"$work/password-input"
        printf 'password\n' >>"$work/trace"
        ;;
    passwd) [ "$2:$3" = '-l:root' ] && printf 'locked\n' >>"$work/trace" ;;
    *) return 1 ;;
    esac
}
printf '{"dashboard":{"auth":{"password":"setup-fixture"}}}' >"$CONFIG_FILE"
setup
if [ "$(cat "$work/trace")" != $'caddy\netc\npassword\nunlock' ]; then
    printf 'FAIL: fresh setup did not provision the console login before releasing its lock\n' >&2
    exit 1
fi
test "$(cat "$work/password-input")" = 'root:setup-fixture'
printf '{"dashboard":{"auth":{"password":""}}}' >"$CONFIG_FILE"
: >"$work/trace"
setup
test "$(cat "$work/trace")" = $'caddy\netc\nlocked\nunlock'
appliance=false
: >"$work/trace"
setup
test "$(cat "$work/trace")" = $'caddy\nunlock'
printf 'PASS: real setup provisions the appliance console before unlock, locks an empty password and leaves DIY alone\n'
