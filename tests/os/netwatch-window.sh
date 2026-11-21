# shellcheck shell=bash
# shellcheck disable=SC2154  # ip belongs to run.sh; the KVM guest's lease as the harness knows it
_netwatch_home() { printf '%s' "${HOST_SCRATCH:-/tmp}/pithead-netwatch"; }

_netwatch_slug() { printf '%s' "$1" | tr -cs 'A-Za-z0-9.-' '-'; }

_netwatch_engine() {
    local cand
    for cand in docker podman; do
        have "$cand" && "$cand" info >/dev/null 2>&1 && {
            printf '%s' "$cand"
            return 0
        }
    done
    return 1
}

_netwatch_vantage_ip() {
    local addr=""
    addr=$(ip -4 -o addr show dev virbr0 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')
    [ -n "$addr" ] || addr=192.168.122.1
    printf '%s' "$addr"
}

_netwatch_meta_set() { # <meta.env> <KEY> <value>
    local tmp
    tmp=$(mktemp) || return 1
    {
        grep -v "^$2=" "$1" 2>/dev/null
        printf '%s=%s\n' "$2" "$3"
    } >"$tmp" && mv "$tmp" "$1"
}

netwatch_scope_flows() { # <guest ip> <vantage ip> — flows.tsv on stdin -> the virbr0 world on stdout
    awk -v box="$1" -v gw="$2" '
        BEGIN { split(gw, g, "."); pre = g[1] "." g[2] "." g[3] }
        $2 == box || $3 == box || index($2, pre ".") == 1 || index($3, pre ".") == 1 { print }
    '
}

netwatch_verdict_row() { # <window> <0 clean|1 unexpected|2 dead> <detail>
    case "$2" in
    0)
        printf '  \033[1;32m✓\033[0m netwatch %s: %s — capture alive (#4196, non-required leg)\n' "$1" "$3"
        ;;
    1)
        printf '  \033[1;31m✗\033[0m netwatch %s (non-required leg, #4196): %s — the classifier refused flows the config does not permit\n' "$1" "$3"
        ;;
    *)
        printf '  \033[1;31m✗\033[0m netwatch %s (non-required leg, #4196): DEAD CAPTURE — %s — silence from a dead instrument is not a clean network\n' "$1" "$3"
        ;;
    esac
}

netwatch_window_start() { # <window name>
    local window="$1" engine out rc=0
    NW_WINDOW=""
    engine=$(_netwatch_engine) || {
        it_skip_leg "netwatch $window window" "no usable container engine on the KVM host for the conntrack recorder" missing
        return 0
    }
    mkdir -p "$(_netwatch_home)" || {
        it_skip_leg "netwatch $window window" "the host scratch directory could not be created for captures" missing
        return 0
    }
    out="$(_netwatch_home)/$(_netwatch_slug "$window")"
    "$engine" image inspect pithead-netwatch:test >/dev/null 2>&1 ||
        timeout 600 "$engine" build -q -t pithead-netwatch:test "$SCRIPT_DIR/../netwatch" >/dev/null 2>&1 || {
        it_skip_leg "netwatch $window window" "the pithead-netwatch recorder image could not be built on this bench" missing
        return 0
    }
    NW_ENGINE="$engine" NW_OUT="$out"
    NETWATCH_ENGINE="$engine" bash "${NW_CLI:-$SCRIPT_DIR/../netwatch/netwatch.sh}" start \
        --out "$out" --vantage "$(_netwatch_vantage_ip)" --box "${ip:-}" 2>&1 |
        sed 's/^/     /' || rc=$?
    if [ "$rc" -ne 0 ]; then
        netwatch_verdict_row "$window" 2 "the recorder refused to start on the KVM host"
        return 0
    fi
    NW_WINDOW="$window"
}

netwatch_window_stop() { # <window name> — stop, classify at the perimeter vantage, record the row
    local window="$1" engine rc=0 out gw seen bad flows=""
    [ "${NW_WINDOW:-}" = "$window" ] || return 0
    NW_WINDOW=""
    engine="${NW_ENGINE:-}"
    out="${NW_OUT:-}"
    [ -n "$engine" ] && [ -n "$out" ] || return 0
    NETWATCH_ENGINE="$engine" bash "${NW_CLI:-$SCRIPT_DIR/../netwatch/netwatch.sh}" stop --out "$out" 2>&1 |
        sed 's/^/     /' || rc=$?
    if [ "$rc" -ne 0 ]; then
        netwatch_verdict_row "$window" 2 "the recorder was not recording until the window closed"
        return 0
    fi
    gw=$(_netwatch_vantage_ip)
    _netwatch_meta_set "$out/meta.env" NW_BOX_IP "${ip:-}"
    _netwatch_meta_set "$out/meta.env" NW_RESOLVER_IP "$gw"
    local scoped n_all n_kept
    scoped="$out/flows.virbr0.tsv"
    netwatch_scope_flows "${ip:-}" "$gw" <"$out/flows.tsv" >"$scoped"
    n_all=$( (grep -c . "$out/flows.tsv" 2>/dev/null) || echo 0)
    n_kept=$( (grep -c . "$scoped" 2>/dev/null) || echo 0)
    [ "$n_kept" != "$n_all" ] &&
        info "netwatch: $n_kept of $n_all recorded flows touch the guest or the virbr0 subnet; the rest is bench-side host traffic outside the audited subject"
    mv "$scoped" "$out/flows.tsv"
    _ssh 'cat /data/pithead/config.json 2>/dev/null' | tr -d '\r' >"$out/config.json" 2>/dev/null
    jq -e . "$out/config.json" >/dev/null 2>&1 || printf '{}\n' >"$out/config.json"
    flows=$(NW_MODE=perimeter NW_RESOLVER_IP="$gw" NETWATCH_ENGINE="$engine" \
        bash "${NW_CLI:-$SCRIPT_DIR/../netwatch/netwatch.sh}" verify --out "$out" --config "$out/config.json" 2>&1) || rc=$?
    printf '%s\n' "$flows" | sed 's/^/     /'
    seen=$(printf '%s\n' "$flows" | sed -n 's/^netwatch: \([0-9][0-9]*\) unique flows observed$/\1/p')
    bad=$(printf '%s\n' "$flows" | sed -n 's/^netwatch: \([0-9][0-9]*\) UNEXPECTED flow.*/\1/p')
    case "$rc" in
    0) netwatch_verdict_row "$window" 0 "${seen:-0} recorded flows, every one permitted by the config" ;;
    1) netwatch_verdict_row "$window" 1 "${bad:-at least one} unexpected flow(s) among ${seen:-unknown} recorded" ;;
    *) netwatch_verdict_row "$window" 2 "no flows at all were recorded during the window" ;;
    esac
}

netwatch_mining_hour() { # <role label> — one hour of passive capture while the box does its work
    local label="$1" n=0
    local total="${NW_MINING_MINUTES:-60}"
    netwatch_window_start "one hour of mining ($label)"
    [ -n "${NW_WINDOW:-}" ] || return 0
    while [ "$n" -lt "$total" ]; do
        sleep 60
        n=$((n + 1))
        [ $((n % 10)) -eq 0 ] &&
            info "netwatch: mining-hour capture at $n of $total minutes ($label)"
    done
    netwatch_window_stop "one hour of mining ($label)"
}

netwatch_htpdate_row() {
    local st=""
    st=$(_ssh 'systemctl is-enabled htpdate 2>&1' | tr -d '\r\n') || st=""
    ok "htpdate unit on the booted image reads ${st:-unreadable} (#4196: recorded for the egress audit, the result is posted to the parent issue)"
}
