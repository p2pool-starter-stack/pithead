# --- Dashboard control channel (#33) ---
# The dashboard container can only ASK: it drops typed JSON intents into $CONTROL_DIR/requests
# (its single writable spool mount). This host-side runner claims each request, validates it, and
# dispatches a FIXED set of actions, each a hardcoded host command the request's `action` string
# only SELECTS between — `apply --dry-run --porcelain` (preview), `apply -y` (commit), `upgrade`
# to the latest published release (#59, target re-derived host-side), `restart`/`apply` (the
# Telegram lifecycle verbs, #338), `worker-apply`/`worker-upgrade` (a rig's own control API,
# #185/#597), `backup` (an encrypted archive + one-time emergency kit, #908), the five staged
# appliance OS-update verbs `os-check`/`os-download`/`os-verify`/`os-install`/`os-reboot`
# (47-/48-os-update-*.sh), and the two read-only diagnostics verbs `diag-doctor`/`diag-logs`
# (#913/#943, 46a-control-diagnostics.sh). The dispatching `case` in 49-control-request-loop.sh
# is the list this sentence must match; check it there before trusting this one.
# Outcomes land in results/ and an audit line in audit/, both mounted read-only in the container —
# as is masked/, the pre-masked config copy the editor form prefills from (#440); the raw
# config.json is never mounted, so the editor/browser receives no existing secret from that path.
# Runtime credentials the dashboard consumes still enter its process environment.
# No string from the container is ever executed or interpolated into a command; the candidate
# config crosses the boundary only as a FILE handed to `apply` via PITHEAD_CONFIG_FILE.

# Approval gate for a commit (#33). Dashboard authentication is the access-control perimeter.
# The client-side APPLY and payout-suffix prompts are typo protection: a compromised dashboard
# process writes the request spool and can supply them itself. Named low-risk keys use the tiers
# below; every other schema-backed env change is promoted to confirmation by the host preview and
# gate. Physical-presence paths remain refused before that classification.
#
# #1959 deliberately restores confirmation as the fallback for schema-backed values. This accepts
# that a compromised dashboard can supply its own actor, APPLY token, envelope and payout suffix;
# the prompts prevent operator mistakes, not hostile requests. The physical-presence paths below
# and the schema/SSRF/data-root/reachability validators remain host-enforced boundaries.
#
# The checks re-derive the changed keys from the staged config via the SAME dry-run path a preview
# runs — nothing is trusted from the container's request or its (host-written but container-visible)
# result file — so a forged "destructive:false" cannot slip a wallet swap or an auth-disable
# through. Past that pass, a DEST row or a worker-descriptor change additionally demands the typed
# envelope, and a payout destination demands the final characters of the exact new address. The
# media-only set below remains outside all of it: no browser approval makes one of those changes
# committable. Echoes a reason on refusal.

# The direct-commit env keys: bounded operational tuning that needs neither APPLY nor the approval
# envelope. Every other schema-backed value falls through to confirmation. WALLET_CHANGED and
# CLEARNET_EXPOSED remain physical-presence-only because they are the detection controls for the
# sensitive changes that #1959 now permits. Space-separated exact env-key names.
#
# NOTE (2026-08 audit): TELEGRAM_EVENT_RAFFLE_WIN was missing from this list for a while — the one
# event toggle out of step with its 24 siblings, all otherwise editable. If you add a new event
# toggle, list it here AND in control_service.EDITABLE_ENV_KEY_PATHS (dashboard) — the drift
# guard only catches a mismatch between the two, not an omission from both.
CONTROL_DASHBOARD_EDITABLE_KEYS='P2POOL_FLAGS P2POOL_PORT
    XVB_ENABLED XVB_DONATION_LEVEL TARI_REQUIRED DASHBOARD_FAIL_CLOSED
    DASHBOARD_CHECK_UPDATES DASHBOARD_TZ
    MONERO_MEM_LIMIT TARI_MEM_LIMIT MONERO_PREP_THREADS
    HASHRATE_DROP_THRESHOLD_PCT HASHRATE_DROP_MINUTES TELEGRAM_DAILY_SUMMARY_TIME
    TELEGRAM_EVENT_NODE_DOWN TELEGRAM_EVENT_NODE_RECOVERED
    TELEGRAM_EVENT_WORKER_OFFLINE TELEGRAM_EVENT_WORKER_RECOVERED
    TELEGRAM_EVENT_WORKER_JOINED TELEGRAM_EVENT_WORKER_LEFT
    TELEGRAM_EVENT_SYNC_FINISHED TELEGRAM_EVENT_DISK_SPACE
    TELEGRAM_EVENT_DB_UNHEALTHY TELEGRAM_EVENT_DB_RESET TELEGRAM_EVENT_XVB_NO_SHARE
    TELEGRAM_EVENT_XVB_REGISTRATION TELEGRAM_EVENT_NEW_RELEASE
    TELEGRAM_EVENT_STACK_ONLINE TELEGRAM_EVENT_DAILY_SUMMARY
    TELEGRAM_EVENT_HASHRATE_LOW TELEGRAM_EVENT_HASHRATE_LOSS
    TELEGRAM_EVENT_HUGEPAGES TELEGRAM_EVENT_LOW_RAM
    TELEGRAM_EVENT_HIGH_REJECT_RATE TELEGRAM_EVENT_BLOCK_FOUND
    TELEGRAM_EVENT_PAYOUT_FOUND TELEGRAM_EVENT_PAYOUT_CONFIRMED TELEGRAM_EVENT_CONTAINER_UNHEALTHY
    TELEGRAM_EVENT_RAFFLE_WIN'

# Explicit confirm keys (#719) tell the form which existing operational fields need APPLY and retain
# their direction-specific preview copy. Unlisted schema-backed values receive the same treatment
# dynamically at preview and commit. Node endpoints also run the host-side reachability probe; data
# directories keep the tighter destination allowlist. COMPOSE_PROFILES rides with tari.mode and the
# exact rendered token set stays pinned by test-control-editable-allowlist.sh.
CONTROL_DASHBOARD_CONFIRM_KEYS='MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR
    STRATUM_PORT MONERO_CLEARNET_SYNC TARI_CLEARNET_SYNC MONERO_PRUNE
    MONERO_OUT_PEERS TARI_MODE COMPOSE_PROFILES
    MONERO_NODE_HOST MONERO_RPC_PORT MONERO_ZMQ_PORT TARI_GRPC_ADDRESS'

# Legacy approval-envelope keys. The container can write this envelope, so it is confirmation
# metadata rather than a second identity. The two tamper alarms remain in NEVER_PATHS. Config-only
# sensitive values such as price_feed and workers.list are named directly in the gate.
CONTROL_DASHBOARD_APPROVAL_KEYS='TELEGRAM_ENABLED TELEGRAM_COMMANDS_ENABLED'

# Config-path distinctions hidden inside a direct env row. P2POOL_FLAGS also carries p2pool.pool,
# which remains ordinary, so the host checks the changed source path before accepting that row.
CONTROL_DASHBOARD_CONFIRM_PATHS='p2pool.clearnet'

# One alternation for the named tiers; preview and gate treat every non-match as confirmed.
control_committable_re() {
    printf '%s %s %s' "$CONTROL_DASHBOARD_EDITABLE_KEYS" "$CONTROL_DASHBOARD_CONFIRM_KEYS" \
        "$CONTROL_DASHBOARD_APPROVAL_KEYS" | tr -s ' \n' '|' | sed 's/^|*//;s/|*$//'
}

# The node-endpoint subset of the confirm set, named ONCE (#1888) so the approval gate's probe
# trigger is not a fourth hand-kept copy of these key names. Every key here must also be in
# CONTROL_DASHBOARD_CONFIRM_KEYS above — a key here but not there is unreachable; a node key there
# but not here would be committable with NO reachability probe, which is the failure that matters.
CONTROL_NODE_ENDPOINT_KEYS='MONERO_NODE_HOST MONERO_RPC_PORT MONERO_ZMQ_PORT TARI_GRPC_ADDRESS'

# Physical-presence-only configuration, matching pithead-media-config's never-approve boundary:
# SSH, the dashboard password, and the two tamper alarms. Exact dotted paths/prefixes, space
# separated. This is checked against config paths before anything else in the commit gate.
CONTROL_DASHBOARD_NEVER_PATHS='ssh dashboard.auth.password
    telegram.events.wallet_changed telegram.events.clearnet_exposed'

# True if $1 is EXACTLY a canonical dotted-decimal IPv4 literal — four decimal octets 0-255, none
# with a leading zero (a bare "0" is fine; "010"/"0177" are not). curl/glibc's numeric-address
# parsing also accepts a bare decimal integer ("2130706433"), octal per-octet ("0177.0.0.1", AND
# bash's own arithmetic tests would misread "010" as octal 8), hex ("0x7f000001"), and
# short/collapsed forms ("127.1" == 127.0.0.1) — none of those are "canonical" by this definition,
# on purpose. Used two ways below: to fast-path an already-clean literal straight to a
# classification with no resolver round trip, and to recognize a RESOLVED answer's own shape
# (getent's output is always canonical, so this always matches there).
_is_canonical_ipv4() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
    return 0
}

# True if a CANONICAL IPv4 address (already _is_canonical_ipv4-shaped) is inside this host's own
# reach: loopback/this-network (0.x/127.x — all of 127.0.0.0/8, not just 127.0.0.1, so a box's own
# non-default loopback alias is caught too), link-local (169.254.0.0/16, which also covers the
# 169.254.169.254 cloud-metadata address), multicast/reserved (224-255), or the stack's own
# docker-bridge /24 (network.subnet, read from the LIVE config — a same-commit network.subnet
# change is refused elsewhere, on neither editable allowlist, so the live value is the honest
# baseline either way). RFC1918 LAN ranges (10/8, 172.16/12, 192.168/16) are deliberately NOT on
# this list — dialing a LAN rig is this feature's whole purpose.
_ipv4_is_sensitive() {
    local a b prefix
    IFS=. read -r a b _ _ <<<"$1"
    case "$a" in
    0 | 127) return 0 ;;
    169) [ "$b" = 254 ] && return 0 ;;
    esac
    [ "$a" -ge 224 ] && return 0
    prefix=$(jq -r '.network.subnet // "172.28.0.0/24"' "$CONFIG_FILE" 2>/dev/null)
    case "$prefix" in
    *.0/24) prefix="${prefix%.0/24}" ;;
    *) prefix="172.28.0" ;;
    esac
    [ "${1%.*}" = "$prefix" ]
}

# True if $1 is shaped like an IPv6 literal — loose on purpose (a bare colon check): this only
# routes the value to the right classifier below, it doesn't itself decide safety.
_is_ipv6_literal() {
    case "$1" in
    *:*) return 0 ;;
    esac
    return 1
}

# True if an IPv6 literal is inside this host's own reach: loopback (::1), unspecified (::),
# link-local (fe80::/10 — the fixed first 10 bits always print as "fe8"/"fe9"/"fea"/"feb" in
# RFC 5952's canonical form, since none of those leading hex digits is ever zero-suppressed),
# multicast (ff00::/8 — this is what actually closes the /etc/hosts multicast aliases
# ip6-allnodes/ip6-allrouters/ip6-localnet/ip6-mcastprefix; a spelling denylist could only ever
# cover the aliases someone thought to type in, never the address CLASS), or an IPv4-mapped IPv6
# literal (::ffff:a.b.c.d) whose EMBEDDED v4 address is itself sensitive — curl dials the
# embedded address, so the v6 wrapper syntax must not launder it.
_ipv6_is_sensitive() {
    local v6
    v6=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    v6="${v6%%%*}" # strip a zone ID (fe80::1%eth0) — irrelevant to which block it's in
    case "$v6" in
    "::1" | "::") return 0 ;;
    fe8[0-9a-f]:* | fe9[0-9a-f]:* | fea[0-9a-f]:* | feb[0-9a-f]:*) return 0 ;;
    ff[0-9a-f][0-9a-f]:*) return 0 ;;
    ::ffff:*.*.*.*)
        _is_canonical_ipv4 "${v6##*:}" && _ipv4_is_sensitive "${v6##*:}" && return 0
        ;;
    esac
    return 1
}

# Resolves $1 to its numeric addresses (both A and AAAA) via the system resolver — once, at
# commit time; this write path is operator-confirmed, never a hot loop, so a real DNS round trip
# here is the right cost for the safety it buys. `getent ahosts` also resolves any numeric-address
# ATTEMPT that isn't the exact canonical form (decimal integer, octal, hex, short/collapsed —
# _is_canonical_ipv4's own comment) using the SAME numeric parsing glibc's getaddrinfo (and
# therefore curl) uses, so routing those through here too gets an exact answer instead of a
# guess. Prints one deduplicated IP per line; a non-zero exit (including a 5s timeout) means
# resolution failed, which the caller treats as FAIL CLOSED — an unresolved name can never be
# proven safe. This is the one seam a test replaces: point $PATH at a directory carrying a fake
# `getent` ahead of the real one (see tests/stack/control/test-control-add-only-ssrf.sh) to supply canned
# answers without needing real DNS.
_resolve_host_ips() {
    timeout 5 getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

# True when the kernel routes an address back to this machine itself. RFC1918 addresses normally
# identify distinct LAN rigs and remain valid, but this host's own LAN address must not turn the
# root control runner into a loopback-by-another-name HTTP client.
_control_ip_is_local() {
    local route
    command -v ip >/dev/null 2>&1 || return 0 # no classifier -> fail closed
    route=$(ip route get "$1" 2>/dev/null) || return 0
    printf '%s\n' "$route" | grep -qE '^local[[:space:]]'
}

# Resolve a worker host to one validated numeric address. Mirrors the READ-path SSRF guard a
# miner-claimed IP already gets (_safe_probe_host,
# dashboard/mining_dashboard/client/xmrig_client.py, #122) for the
# WRITE path: an add-only append is DASHBOARD-chosen (the operator confirms it in the browser, but
# the actual HTTP request is built and sent by the — possibly compromised — dashboard container),
# so without this a malicious/compromised dashboard could append a phantom descriptor pointed at
# its own host's loopback services or a sibling container, then immediately dial it (with an
# attacker-chosen bearer) via the pre-existing worker-apply/worker-upgrade path, which resolves and
# dials strictly from the HOST's own config. An ordinary LAN or public rig address is unaffected.
#
# #893 round 5: an earlier version of this function classified by STRING SHAPE alone — a denylist
# of "localhost" and its known /etc/hosts aliases. An independent review found that a spelling
# denylist can never answer "does this name reach my own loopback": this host's own Debian
# self-entry (e.g. a box named "gouda" resolving to 127.0.1.1 — every Debian install's own
# /etc/hosts gives its hostname a loopback entry) and, worse, ANY attacker-controlled DNS name
# pointed at 127.0.0.1 both looked like "a genuine hostname, therefore safe" to a string
# classifier — but a live curl dial to either one lands on loopback all the same. There is no
# spelling to denylist against an attacker who controls the DNS answer.
#
# The fix is RESOLVE, THEN CHECK: a canonical IPv4 literal (the exact form _is_canonical_ipv4
# recognizes) is classified directly, since it already IS the address that would be dialed and
# has exactly one meaning. Everything else — including an IPv6 literal, which unlike IPv4 has
# many equally-valid spellings of the same address ("::1" == "0:0:0:0:0:0:0:1") that a hand-rolled
# shortcut classifier could under-recognize the same way the old denylist did — goes through the
# resolver, which normalizes any of those the same way glibc's own numeric-address parsing would.
# EVERY returned address must clear the check — an attacker's own DNS answer can mix one public IP
# with one loopback IP in the same response, so checking only the first would miss it.
# Worker control operations pin curl to the returned address; a check followed by a fresh hostname
# lookup would leave a DNS-rebinding window.
_control_resolve_external_ip() {
    local host resolved ip first=""
    host=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    host="${host%.}" # a trailing dot is DNS's "FQDN root" marker; getent treats it identically
    if _is_canonical_ipv4 "$host"; then
        # A canonical dotted-decimal literal is unambiguous — it IS the address that would be
        # dialed, so classify it directly with no resolver round trip.
        { _ipv4_is_sensitive "$host" || _control_ip_is_local "$host"; } && return 1
        printf '%s\n' "$host"
        return 0
    fi
    # Everything else — a genuine hostname, an IPv6 literal in ANY of its many equally-valid
    # spellings ("::1" and "0:0:0:0:0:0:0:1" are the identical address; a hand-rolled
    # canonicalizer here would just reopen the same bug class this fix closed for IPv4 — a
    # classifier that only recognizes ONE shape and silently treats every other shape as safe), or
    # an IPv4-shaped-but-non-canonical numeric-address ATTEMPT (decimal integer, octal, hex,
    # short/collapsed form) — goes through the resolver. `getent ahosts` normalizes ALL of those
    # into canonical addresses using the SAME parsing glibc's getaddrinfo (and therefore curl)
    # uses, including a bare literal (no network round trip needed for one), so this is correct
    # for a typed literal and a real hostname alike.
    resolved=$(_resolve_host_ips "$host") || return 1 # resolution failed/timed out -> FAIL CLOSED
    [ -n "$resolved" ] || return 1                    # an empty answer -> FAIL CLOSED
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if _is_canonical_ipv4 "$ip"; then
            { _ipv4_is_sensitive "$ip" || _control_ip_is_local "$ip"; } && return 1
        elif _is_ipv6_literal "$ip"; then
            { _ipv6_is_sensitive "$ip" || _control_ip_is_local "$ip"; } && return 1
        else
            return 1 # an answer shape we don't recognize -> FAIL CLOSED, never wave it through
        fi
        [ -n "$first" ] || first="$ip"
    done <<<"$resolved"
    [ -n "$first" ] || return 1
    printf '%s\n' "$first"
}

# Boolean compatibility wrapper for commit-time target validation.
_control_host_is_internal() {
    ! _control_resolve_external_ip "$1" >/dev/null
}

# A curl --resolve value whose numeric address has passed the local-target floor. IPv6 addresses
# need brackets in the comma/colon-delimited option value.
_control_worker_curl_pin() { # <host> <port>
    local ip
    ip=$(_control_resolve_external_ip "$1") || return 1
    case "$ip" in *:*) ip="[$ip]" ;; esac
    printf '%s:%s:%s\n' "$1" "$2" "$ip"
}

# Dashboard-confirmed data moves stay inside roots the host already uses. Canonicalize symlinks,
# and reject internal or dashboard-writable ancestors even when their current target is safe: the
# container could otherwise swap one before root-owned mkdir/chown.
control_validate_data_dir_destinations() { # <staged-file>
    local staged="$1" cur root shared_root
    local monero_dir tari_dir p2pool_dir tor_dir control_dir
    local -a allowed_roots=("$PWD/data")
    local -a reserved_paths=() reserved_roots=()
    # A single service under /var/lib/monero must not authorize sibling /var/lib trees. Only the
    # co-located root used by all four host services (#455) can extend the dashboard allowlist, and
    # never when that parent is itself one of assert_safe_dir's broad roots.
    monero_dir=$(env_get MONERO_DATA_DIR)
    tari_dir=$(env_get TARI_DATA_DIR)
    p2pool_dir=$(env_get P2POOL_DATA_DIR)
    tor_dir=$(env_get TOR_DATA_DIR)
    if [ -n "$monero_dir" ] && [ -n "$tari_dir" ] && [ -n "$p2pool_dir" ] && [ -n "$tor_dir" ]; then
        shared_root=$(dirname "$monero_dir")
    else
        shared_root=""
    fi
    if [ -n "$shared_root" ] && [ "$(dirname "$tari_dir")" = "$shared_root" ] &&
        [ "$(dirname "$p2pool_dir")" = "$shared_root" ] &&
        [ "$(dirname "$tor_dir")" = "$shared_root" ]; then
        shared_root=$(realpath -m -- "$shared_root" 2>/dev/null) || shared_root=""
        [ -n "$shared_root" ] && ! _data_dir_is_broad_root "$shared_root" && allowed_roots+=("$shared_root")
    fi
    # The dashboard can replace a symlink below either read-write state mount between this check
    # and root's later mkdir/chown; the control spool must not overlap service data either. Record
    # lexical and canonical forms so neither an existing symlink nor a post-check swap can escape.
    cur=$(env_get DASHBOARD_DATA_DIR)
    [ -n "$cur" ] && reserved_paths+=("$cur")
    control_dir=$(env_get CONTROL_DIR)
    [ -n "$control_dir" ] && reserved_paths+=("$control_dir")
    cur=$(env_get CLEARNET_STATE_DIR)
    [ -n "$cur" ] && reserved_paths+=("$cur")
    for cur in "${reserved_paths[@]}"; do
        root=$(realpath -ms -- "$cur" 2>/dev/null) || root=""
        [ -n "$root" ] && reserved_roots+=("$root")
        root=$(realpath -m -- "$cur" 2>/dev/null) || root=""
        [ -n "$root" ] && reserved_roots+=("$root")
    done

    local ddpath dest dest_real dest_lex root_real ok_root changed_paths
    changed_paths=$(control_changed_config_paths "$staged")
    for ddpath in monero.data_dir tari.data_dir p2pool.data_dir tor.data_dir dashboard.data_dir; do
        printf '%s\n' "$changed_paths" | grep -qxF "$ddpath" || continue
        dest=$(jq -r --arg p "$ddpath" 'getpath($p/".") // empty' "$staged" 2>/dev/null)
        # These exact values resolve to stack-owned defaults. apply's assert_safe_dir has already
        # rejected relative paths and traversal during the dry-run that precedes this helper.
        case "$dest" in "" | auto | DYNAMIC_DATA | DYNAMIC_HOST | DYNAMIC_ID) continue ;; esac
        dest_real=$(realpath -m -- "$dest" 2>/dev/null) || dest_real=""
        dest_lex=$(realpath -ms -- "$dest" 2>/dev/null) || dest_lex=""
        if [ -z "$dest_real" ] || [ -z "$dest_lex" ]; then
            printf 'this move sends %s to a path the host cannot resolve safely. %s' "$ddpath" "$(_control_host_remedy)"
            return 1
        fi
        for root in "${reserved_roots[@]}"; do
            case "$dest_lex/" in "$root"/*)
                printf 'this move sends %s below an internal or dashboard-writable host directory — choose a sibling under an allowed data root. %s' "$ddpath" "$(_control_host_remedy)"
                return 1
                ;;
            esac
            case "$dest_real/" in "$root"/*)
                printf 'this move sends %s through an internal or dashboard-writable host directory — choose a sibling under an allowed data root. %s' "$ddpath" "$(_control_host_remedy)"
                return 1
                ;;
            esac
        done
        ok_root=0
        for root in "${allowed_roots[@]}"; do
            root_real=$(realpath -m -- "$root" 2>/dev/null) || continue
            case "$dest_real/" in "$root_real"/*) ok_root=1 && break ;; esac
        done
        if [ "$ok_root" -eq 0 ]; then
            printf 'this move sends %s to %s, which is outside the stack data root(s) — a dashboard-confirmed data-dir move must stay under the stack data directory (%s) or the dedicated parent shared by Monero, Tari, P2Pool, and Tor. %s' "$ddpath" "$dest" "$PWD/data" "$(_control_host_remedy)"
            return 1
        fi
    done
    return 0
}
