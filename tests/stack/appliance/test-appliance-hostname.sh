# shellcheck shell=bash
: "${STACK_SUITE:?Run through tests/stack/run.sh}"

echo "== unit: coordinator hostname follows saved config only at mutation boundaries =="
HN="$SANDBOX/hostname"
mkdir -p "$HN"

hn_run() {
    (
        cd "$HN" || exit 1
        printf '{}\n' >config.json
        # shellcheck source=/dev/null  # CLI is its own lint root (#2632)
        source "$STACK"
        set -e
        printf 'old-name' >kernel-name
        printf 'old-name' >static-name
        : >calls
        rm -f .env.apply-incomplete Caddyfile
        printf 'HOST_IP=old-name.local\n' >.env
        local kind="$1" mode="${4:-changed}" f
        DASHBOARD_HOST="$2" PITHEAD_DRY_RUN=0
        PITHEAD_AVAHI_CONF="$PWD/absent-avahi.conf"
        is_appliance() { [ "$kind" = appliance ]; }
        hostname() {
            case "${1:-}" in
            -I) printf '192.168.1.10\n' ;;
            '') cat kernel-name ;;
            *)
                printf '%s' "$1" >kernel-name
                printf 'hostname %s\n' "$1" >>calls
                ;;
            esac
        }
        # hostnamectl is the one call left to fix #2350: it must land BOTH names from the single
        # `hostnamectl hostname NAME` verb, so a reader of either — `hostname` (transient) or
        # `hostnamectl --static` — sees the same applied name. ensure_etc_overlay is the real
        # /etc-overlay mount; a no-op here, unit-proven on its own in the mDNS suite below.
        ensure_etc_overlay() { return 0; }
        hostnamectl() {
            case "$1" in
            --static) cat static-name 2>/dev/null || printf 'old-name' ;;
            hostname)
                printf '%s' "$2" >kernel-name
                printf '%s' "$2" >static-name
                printf 'hostname %s\n' "$2" >>calls
                ;;
            esac
        }
        sudo() {
            case "$1" in
            hostname)
                shift
                hostname "$@"
                ;;
            hostnamectl)
                shift
                hostnamectl "$@"
                ;;
            systemctl) printf '%s\n' "$*" >>calls ;;
            *)
                echo "UNEXPECTED sudo" >&2
                exit 91
                ;;
            esac
        }
        error() {
            echo "$*" >&2
            exit 1
        }
        log() { :; }
        warn() { :; }
        case "$3" in
        resolve)
            resolve_dashboard_host
            printf 'host=%s kernel=%s static=%s calls=%s\n' "$HOST_IP" "$(hostname)" "$(hostnamectl --static)" "$(wc -l <calls)"
            ;;
        names)
            resolve_dashboard_host
            printf '%s\n' "$(appliance_cert_alt_string)"
            ;;
        cert)
            resolve_dashboard_host
            PITHEAD_TLS_DIR="$PWD/tls"
            appliance_mint_cert >/dev/null
            cert_san_string "$PITHEAD_TLS_DIR/wizard.crt"
            ;;
        rig)
            printf '{"worker":"%s"}\n' "$5" >rig.json
            reconcile_rig_hostname
            printf 'kernel=%s static=%s calls=%s\n' "$(hostname)" "$(hostnamectl --static)" "$(wc -l <calls)"
            ;;
        reconcile)
            reconcile_appliance_hostname
            printf 'kernel=%s static=%s calls=%s\n' "$(hostname)" "$(hostnamectl --static)" "$(wc -l <calls)"
            ;;
        apply | dry | render | setup)
            # Drive the real verb's ordering; replace only unrelated services and I/O.
            for f in require_env ensure_onion_password parse_and_validate_config load_preserved_state \
                ensure_directories mutation_lock_acquire mutation_lock_release provision_node_onions \
                inject_service_configs provision_control_runner provision_onion_client_auth \
                provision_ssh_access provision_console_login render_local_miner_config \
                migrate_compose_project apply_tor_egress_firewall migrate_dashboard_data \
                provision_local_miner announce_dashboard_url check_prerequisites ensure_config_exists \
                preflight_resources check_stratum_exposure prepare_directories; do
                eval "$f() { :; }"
            done
            onion_missing() { return 1; }
            is_deployed() { return 0; }
            render_env() { printf 'HOST_IP=%s\n' "$HOST_IP" >"${1:-.env}"; }
            env_changed_keys() { [ "$mode" = unchanged ] || echo HOST_IP; }
            env_get_file() { sed -n "s/^$2=//p" "$1"; }
            describe_change() { printf 'INFO\tname changes\n'; }
            generate_caddyfile() { echo "$HOST_IP" >Caddyfile; }
            docker() { :; }
            compose_up_checked() { [ "$mode" != failed ]; }
            # shellcheck disable=SC2034  # read by sourced apply/setup helpers
            DEPLOYMENT_COMPLETED=true P2POOL_ONION=fixture.onion DASHBOARD_ONION_ENABLED=false
            [ "$mode" != retry ] || : >.env.apply-incomplete
            case "$3" in
            apply) (apply --yes) >/dev/null 2>&1 || echo 'apply failed' ;;
            dry) apply --dry-run >/dev/null ;;
            render) render_derived ;;
            setup)
                # Stop just after setup's first render, before any Tor/disk work. The real
                # setup entry path (including validation and hostname hook) still executes.
                is_deployed() { return 1; }
                render_env() {
                    printf '%s' "$HOST_IP" >setup-host
                    exit 0
                }
                (setup) >/dev/null
                ;;
            esac
            printf 'kernel=%s static=%s calls=%s\n' "$(hostname)" "$(hostnamectl --static)" "$(wc -l <calls)"
            ;;
        esac
    )
}

assert_eq "label resolves for mDNS without mutating either hostname" "$(hn_run appliance Garden-Box resolve)" 'host=garden-box.local kernel=old-name static=old-name calls=0'
assert_eq "Docker label is only a dashboard address" "$(hn_run docker garden-box reconcile)" 'kernel=old-name static=old-name calls=0'
for pin in example.test 192.168.1.10 auto '' 'bad name' '-bad' "$(printf 'a%.0s' {1..64})"; do
    assert_eq "legacy or invalid non-label does not rename host" "$(hn_run appliance "$pin" reconcile)" 'kernel=old-name static=old-name calls=0'
done
assert_eq "reconcile sets the kernel AND static name and refreshes Avahi (#2350)" "$(hn_run appliance Garden-Box reconcile)" 'kernel=garden-box static=garden-box calls=2'
assert_eq "a rig takes its hostname from rig.json's worker, not dashboard.host" "$(hn_run appliance dashboard-name rig changed shed-3)" 'kernel=shed-3 static=shed-3 calls=2'
for worker in '' 'Bad_Name' 'bad name' localhost auto; do
    assert_eq "a rig worker that is no valid label leaves the hostname alone" "$(hn_run appliance dashboard-name rig changed "$worker")" 'kernel=old-name static=old-name calls=0'
done
assert_eq "existing name still retries mDNS announcement" "$(hn_run appliance old-name reconcile)" 'kernel=old-name static=old-name calls=1'
assert_eq "named cert includes mDNS and permitted IP" "$(hn_run appliance garden-box names)" 'DNS:garden-box.local,IP:192.168.1.10,DNS:localhost'
assert_contains "minted certificate follows resolved name" "$(hn_run appliance garden-box cert)" 'DNS:garden-box.local'
HN_LONG=$(printf 'a%.0s' {1..63})
assert_contains "longest valid machine label mints its full SAN" "$(hn_run appliance "$HN_LONG" cert)" "DNS:$HN_LONG.local"
unset HN_LONG
assert_not_contains "name change removes old cert name" "$(hn_run appliance next-box cert)" 'DNS:garden-box.local'
for op in setup render apply; do
    assert_eq "$op reconciles appliance name" "$(hn_run appliance garden-box "$op")" 'kernel=garden-box static=garden-box calls=2'
done
for mode in unchanged retry; do
    assert_eq "$mode apply reconciles identity" "$(hn_run appliance garden-box apply "$mode")" 'kernel=garden-box static=garden-box calls=2'
done
assert_contains "failed apply keeps old hostname" "$(hn_run appliance garden-box apply failed)" 'kernel=old-name static=old-name calls=0'
assert_eq "dry-run does not touch either hostname or Avahi" "$(hn_run appliance garden-box dry)" 'kernel=old-name static=old-name calls=0'
assert_eq "Docker apply with external DNS preserves host" "$(hn_run docker example.test apply)" 'kernel=old-name static=old-name calls=0'
unset HN

echo "== unit: mDNS is published on this machine's NICs, never on a container bridge (#2060) =="
MD="$SANDBOX/mdns"
mkdir -p "$MD"

# Real `ip` output from the guest the issue was measured on: one LAN NIC and the engine's two
# bridges, the second of which owns 172.28.0.1 — one of the two addresses <name>.local wrongly
# resolved to. `ip link ... type bridge` is what tells them apart, so the stub answers both forms.
md_run() { # <operation> [conf-body-mode]
    (
        cd "$MD" || exit 1
        # shellcheck source=/dev/null  # CLI is its own lint root (#2632)
        source "$STACK"
        set -e
        : >calls
        local op="$1" conf_mode="${2:-shipped}"
        is_appliance() { return 0; }
        log() { :; }
        warn() { printf 'warn\n' >>calls; }
        ip() {
            case "$*" in
            *'type bridge'*)
                printf '3: podman1: <BROADCAST,MULTICAST,UP> mtu 1500 state UP\n'
                printf '4: podman2: <BROADCAST,MULTICAST,UP> mtu 1500 state UP\n'
                ;;
            *'-4 -o addr'*)
                printf '2: enp1s0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic enp1s0\\       valid_lft 84559sec\n'
                printf '3: podman1    inet 10.89.0.1/24 brd 10.89.0.255 scope global podman1\\       valid_lft forever\n'
                printf '4: podman2    inet 172.28.0.1/24 brd 172.28.0.255 scope global podman2\\       valid_lft forever\n'
                ;;
            esac
        }
        case "$conf_mode" in
        shipped) printf '[server]\n#allow-interfaces=eth0\nuse-ipv6=no\n' >avahi.conf ;;
        noline) printf '[server]\nuse-ipv6=no\n' >avahi.conf ;;
        missing) rm -f avahi.conf ;;
        esac
        # shellcheck disable=SC2034  # read by the sourced Avahi helper
        PITHEAD_AVAHI_CONF="$PWD/avahi.conf"
        ensure_etc_overlay() { printf 'overlay\n' >>calls; }
        sudo_sed() { sed -i.bak "$1" "$2" && rm -f "$2.bak"; }
        case "$op" in
        list) appliance_mdns_interfaces ;;
        noip)
            ip() { :; }
            printf '[%s]\n' "$(appliance_mdns_interfaces)"
            ;;
        write)
            appliance_reconcile_mdns_interfaces && printf 'changed\n' || printf 'unchanged\n'
            grep '^allow-interfaces=' avahi.conf 2>/dev/null || echo 'no allow-interfaces line'
            ;;
        twice)
            appliance_reconcile_mdns_interfaces >/dev/null 2>&1 || true
            appliance_reconcile_mdns_interfaces && printf 'changed\n' || printf 'unchanged\n'
            ;;
        reconcile)
            # shellcheck disable=SC2034  # read by sourced hostname helpers
            DASHBOARD_HOST=auto PITHEAD_DRY_RUN=0
            hostname() { printf 'pithead'; }
            sudo() { printf '%s\n' "$*" >>calls; }
            reconcile_appliance_hostname
            printf 'calls=%s\n' "$(tr '\n' ' ' <calls)"
            ;;
        esac
    )
}

assert_eq "only the LAN NIC is published, both bridges dropped" "$(md_run list)" 'enp1s0'
assert_eq "no addressed NIC yet means no interface policy at all" "$(md_run noip)" '[]'
assert_eq "the shipped commented line is rewritten in place" "$(md_run write)" 'changed
allow-interfaces=enp1s0'
assert_eq "an unchanged policy does not refresh the daemon" "$(md_run twice)" 'unchanged'
# The read-back control: strip the line the sed matches and the rewrite becomes a no-op. Without
# it the function returned "changed" on a file it had not touched, and the caller restarted Avahi
# onto an unrestricted config believing the opposite.
assert_eq "a config with no allow-interfaces line reports no change" "$(md_run write noline)" 'unchanged
no allow-interfaces line'
assert_eq "no avahi config at all is left alone" "$(md_run write missing)" 'unchanged
no allow-interfaces line'
# The wiring the defect needed: an appliance on the default "auto" name has no label to reconcile
# and was returning before Avahi was ever touched, so it kept announcing itself on the bridges.
assert_eq "an auto-named appliance still refreshes Avahi" "$(md_run reconcile)" \
    'calls=overlay systemctl try-restart avahi-daemon.service '
unset MD

echo "== unit: the machine-name rule is one rule with one message (#3810) =="
NM="$SANDBOX/machine-name"
mkdir -p "$NM"
nm_run() {
    (
        cd "$NM" || exit 1
        # shellcheck source=/dev/null  # CLI is its own lint root (#2632)
        source "$STACK"
        set -eu
        case "$1" in
        label) is_machine_name_label "$2" ;;
        rule) printf '%s\n' "$MACHINE_NAME_RULE" ;;
        inuse)
            is_appliance() { [ "${FAKE_APPLIANCE:-1}" = 1 ]; }
            getent() { printf '%s\n' "$FAKE_ANSWERS"; }
            hostname() { printf '192.168.1.10 10.0.0.5\n'; }
            if appliance_mdns_name_in_use box; then printf in-use; else printf free; fi
            ;;
        warn)
            is_appliance() { return 0; }
            getent() { printf '%s\n' "$FAKE_ANSWERS"; }
            hostname() { printf '192.168.1.10\n'; }
            machine_name_warning box rig
            ;;
        ask)
            printf '{}\n' >cfg.json
            [ -z "${NOCFG:-}" ] || rm -f cfg.json
            python3 - "$STACK" "$PWD/cfg.json" "$2" "$3" <<'PY'
import os, pty, re, select, subprocess, sys
stack, cfg, appliance, answers = sys.argv[1:5]
master, slave = pty.openpty()
script = (
    'kind=$3; source "$1"; unset DASHBOARD_HOST HOST_IP PRESERVED_HOST_IP; '
    'hostname() { echo box; }; '
    'is_appliance() { [ "$kind" = 1 ]; }; resolve_dashboard_host interactive; '
    'printf "host=%s\\n" "$HOST_IP"'
)
proc = subprocess.Popen(["bash", "-c", script, "bash", stack, cfg, appliance], stdin=slave, stdout=slave, stderr=slave, env={**os.environ, "PITHEAD_CONFIG_FILE": cfg})
os.write(master, answers.encode().decode("unicode_escape").encode())
out = b""
while select.select([master], [], [], 0.2)[0] or proc.poll() is None:
    out += os.read(master, 4096)
text = out.decode()
host = re.search(r"host=\S+", text)[0]
saved = subprocess.run(["jq", "-r", ".dashboard.host // \"none\"", cfg], capture_output=True, text=True).stdout.strip()
print(f"{host} saved={saved} rule={text.count('lowercase letters, digits or hyphens')} unsaved={text.count('applies to this run only')}")
PY
            ;;
        esac
    )
}
assert_eq "plain labels are accepted" "$(
    for good in a 7 pithead garden-box "$(printf 'a%.0s' {1..63})"; do
        nm_run label "$good" && printf 'yes ' || printf 'no '
    done
)" 'yes yes yes yes yes '
assert_eq "reserved words, cases, lengths and shapes are refused" "$(
    for bad in '' Auto Box localhost auto a-box- '-a' 'a b' 'a.b' "$(printf 'a%.0s' {1..64})"; do
        nm_run label "$bad" && printf 'wrong ' || printf 'no '
    done
)" 'no no no no no no no no no no '
assert_eq "the rule names the reserved words it refuses" "$(nm_run rule)" \
    'Name this machine: 1–63 lowercase letters, digits or hyphens, starting and ending with a letter or digit; auto and localhost are reserved.'
assert_eq "a name answering only on this machine's own address is free" \
    "$(FAKE_ANSWERS='10.0.0.5' nm_run inuse)" free
assert_eq "a name also answered by another machine is in use" \
    "$(FAKE_ANSWERS='192.0.2.5
10.0.0.5' nm_run inuse)" in-use
assert_eq "a name another machine answers is in use" "$(FAKE_ANSWERS='192.0.2.5' nm_run inuse)" in-use
assert_eq "an unanswered name is free" "$(FAKE_ANSWERS='' nm_run inuse)" free
assert_eq "off the appliance nothing is ever announced" "$(FAKE_APPLIANCE=0 FAKE_ANSWERS='192.0.2.5' nm_run inuse)" free
assert_eq "DIY setup reads no hostname input" "$(nm_run ask 0 'evil-name\n')" "host=box saved=none rule=0 unsaved=0"
assert_eq "an appliance refuses a bad name, explains the rule, then keeps the good one" \
    "$(nm_run ask 1 'Bad_Name\ngarden-box\n')" "host=garden-box.local saved=garden-box rule=1 unsaved=0"
assert_eq "an empty answer keeps the default name and saves nothing" "$(nm_run ask 1 '\n')" "host=box.local saved=none rule=0 unsaved=0"
assert_eq "an unsaved name is reported, not swallowed" "$(NOCFG=1 nm_run ask 1 'garden-box\n')" "host=garden-box.local saved= rule=0 unsaved=1"
assert_eq "an in-use name carries the warning text and a free one carries none" \
    "$(FAKE_ANSWERS='192.0.2.5' nm_run warn)|$(FAKE_ANSWERS='' nm_run warn)" \
    "Another machine on this network already answers box.local — give this rig a different name if both must be reachable.|"
