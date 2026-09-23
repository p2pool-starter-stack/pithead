#!/usr/bin/env bash
# Trust, rollback, continuity, and live-state predicate helpers.

LIVE_COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign@sha256:4bedb8de1c5c1abd8dea60de704ba449402d238623fa8bb33d2ccaa9beffcbf5"
CANDIDATE_BUNDLE=""
CANDIDATE_SIGNATURE=""
TRUSTED_COSIGN_PUB=""
UPGRADE_STAGE_DIR=""
UPGRADE_BUNDLE_SNAPSHOT=""
UPGRADE_SIGNATURE_SNAPSHOT=""
UPGRADE_TRUSTED_KEY=""
UPGRADE_ROLLBACK_DIR=""
UPGRADE_BASELINE_DIR=""
UPGRADE_CANDIDATE_DIR=""
UPGRADE_CURRENT_LINK=""
UPGRADE_CANDIDATE_REFS=""
UPGRADE_CANDIDATE_ALL_REFS=""
UPGRADE_BEFORE_REFS=""
UPGRADE_BEFORE_REVISIONS=""
UPGRADE_BEFORE_SECRETS=""
UPGRADE_BEFORE_TELEMETRY=""
UPGRADE_TELEMETRY_EPOCH=""
UPGRADE_BEFORE_MOUNTS=""
UPGRADE_BEFORE_WORKERS=""
UPGRADE_BEFORE_MONERO=""
UPGRADE_BEFORE_TARI=""
UPGRADE_BEFORE_MONERO_ID=""
UPGRADE_BEFORE_TARI_ID=""
_UPGRADE_RESTORE_ARMED=0
_UPGRADE_FOREIGN_TRAP=""

valid_full_sha() { [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]; }
revision_matches_sha() { valid_full_sha "${2:-}" && [ "${1:-}" = "$2" ]; }
height_continues() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "${2:-}" =~ ^[0-9]+$ ]] && [ "$2" -ge "$1" ]
}

validate_live_gate_args() {
    if [ "$RUN_IMAGE_UPGRADE" = "1" ]; then
        [ "$IT_MODE" = "local" ] || {
            it_err "--image-upgrade requires --local so trusted rollback stays on the locked host."
            exit 2
        }
        local file
        for file in "$CANDIDATE_BUNDLE" "$CANDIDATE_SIGNATURE" "$TRUSTED_COSIGN_PUB"; do
            case "$file" in /*) ;; *)
                it_err "--image-upgrade requires --candidate-bundle with three absolute paths."
                exit 2
                ;;
            esac
            [ -f "$file" ] && [ ! -L "$file" ] || {
                it_err "Trusted candidate input is not a regular non-symlink file: $file"
                exit 2
            }
        done
    fi
    if [ "$RUN_XVB_ROUTING" = "1" ] && [ "$SAFETY_BACKUP" != "1" ]; then
        it_err "--xvb-routing-smoke requires --safety-backup."
        exit 2
    fi
}

dashboard_image_revision() {
    rx "docker inspect dashboard --format '{{ index .Config.Labels \"org.opencontainers.image.revision\" }}' 2>/dev/null"
}
compose_image_ids() {
    rx 'docker compose ps -q 2>/dev/null | while read -r c; do docker inspect --format "{{.Name}} {{.Image}}" "$c"; done | sort'
}
first_party_revisions() {
    rx 'for s in tor monerod wallet-rpc p2pool xmrig-proxy dashboard; do c=$(docker compose ps -q "$s" 2>/dev/null | head -n1); [ -z "$c" ] || docker inspect --format "$s {{ index .Config.Labels \"org.opencontainers.image.revision\" }}" "$c"; done'
}
revisions_match_sha() { # <service/revision lines> <full-sha>
    local name rev seen=""
    while read -r name rev; do
        [ -n "$name" ] || continue
        revision_matches_sha "$rev" "$2" || return 1
        seen="$seen $name"
    done <<<"$1"
    case "$seen" in *" tor"*" p2pool"*" xmrig-proxy"*" dashboard"*) return 0 ;; esac
    return 1
}
first_party_running_refs() {
    rx 'for s in tor monerod p2pool xmrig-proxy dashboard; do c=$(docker compose ps -q "$s" 2>/dev/null | head -n1); [ -n "$c" ] || exit 1; docker inspect --format "$s {{.Config.Image}}" "$c"; done'
}
pinned_refs_valid() {
    local name ref seen=""
    while read -r name ref; do
        [[ "$ref" =~ @sha256:[0-9a-f]{64}$ ]] || return 1
        seen="$seen $name"
    done <<<"$1"
    [ "$seen" = " tor monerod p2pool xmrig-proxy dashboard" ]
}
worker_names() { api_state | jq -r '.workers[]?.name' 2>/dev/null | sort -u; }
_pred_worker_set() { [ "$(worker_names)" = "$1" ]; }
all_running_refs() {
    rx 'docker compose ps --services --status running 2>/dev/null | sort | while read -r s; do c=$(docker compose ps -q "$s" | head -n1); [ -n "$c" ] || exit 1; docker inspect --format "$s {{.Config.Image}}" "$c"; done'
}
stateful_mounts() {
    rx 'set -euo pipefail; docker compose ps --services --status running | while read -r s; do [ -n "$s" ] || continue; c=$(docker compose ps -q "$s" | head -n1); [ -n "$c" ]; docker inspect "$c" | jq -r --arg s "$s" '\''.[0].Mounts[] | select(.RW == true and (.Destination | IN("/var/lib/tor","/home/ubuntu/.bitmonero","/home/ubuntu/wallets","/var/tari/node","/home/ubuntu/wallet","/home/ubuntu","/data","/clearnet-state","/control/requests","/var/log/caddy"))) | [$s,.Destination,.Source,.Type] | @tsv'\''; done | sort'
}
normalized_stateful_mounts() { # <version-dir> <mount TSV>
    awk -F '\t' -v OFS='\t' -v root="$1" '$2 == "/clearnet-state" || $2 == "/control/requests" || $2 == "/var/log/caddy" { prefix=root "/data/"; if (index($3,prefix) != 1) exit 1; $3="@release/data/" substr($3,length(prefix)+1) } { print }' <<<"$2"
}
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Categorized, target-side hashes for state an upgrade or XvB smoke must not rotate. Only digests
# cross SSH or enter artifacts; missing/unreadable categories fail instead of hashing empty input.
upgrade_secret_fingerprints() {
    local keys fp
    for keys in \
        'wallet:^(MONERO_WALLET_ADDRESS|MONERO_VIEW_KEY|TARI_WALLET_ADDRESS|TARI_WALLET_PASSWORD|TARI_VIEW_KEY|TARI_SPEND_PUBLIC_KEY)=' \
        'proxy:^(PROXY_AUTH_TOKEN|PROXY_STRATUM_PASSWORD|XMRIG_API_TOKEN)=' \
        'dashboard:^(DASHBOARD_AUTH_USER|DASHBOARD_AUTH_HASH_B64|DASHBOARD_AUTH_PW_FP)=' \
        'rpc:^(MONERO_NODE_USERNAME|MONERO_NODE_PASSWORD|WALLET_RPC_USERNAME|WALLET_RPC_PASSWORD)=' \
        'onion-env:^([A-Z]+_ONION_ADDRESS|DASHBOARD_ONION_CLIENT_(PUBKEY|PRIVKEY))='; do
        fp="$(rx "v=\$(grep -E $(quote_arg "${keys#*:}") .env 2>/dev/null | sort); [ -n \"\$v\" ] || exit 1; printf '%s\\n' \"\$v\" | sha256sum | cut -d' ' -f1")" || return 1
        [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf '%s=%s\n' "${keys%%:*}" "$fp"
    done
    fp="$(rx 'd=$(grep -E "^TOR_DATA_DIR=" .env | head -n1 | cut -d= -f2-); [ -n "$d" ] && [ -d "$d" ] && [ ! -L "$d" ] || exit 1; v=""; for pair in P2POOL:p2pool MONERO:monero TARI:tari DASHBOARD:dashboard; do key=${pair%%:*}_ONION_ADDRESS; svc=${pair#*:}; addr=$(grep -E "^$key=" .env | head -n1 | cut -d= -f2-); sd="$d/$svc"; if sudo -n test -e "$sd"; then :; elif sudo -n test ! -e "$sd"; then [ -z "$addr" ] || [ "$addr" = placeholder ] || exit 1; continue; else exit 1; fi; sudo -n test -d "$sd" && sudo -n test ! -L "$sd" || exit 1; members=$(sudo -n find "$sd" -mindepth 1 -maxdepth 1 -print) || exit 1; while IFS= read -r p; do [ -n "$p" ] || continue; name=${p##*/}; case "$name" in hostname|hs_ed25519_secret_key|hs_ed25519_public_key) sudo -n test -f "$p" && sudo -n test ! -L "$p" || exit 1 ;; authorized_clients) sudo -n test -d "$p" && sudo -n test ! -L "$p" || exit 1 ;; *) exit 1 ;; esac; done <<<"$members"; for name in hostname hs_ed25519_secret_key hs_ed25519_public_key; do p="$sd/$name"; sudo -n test -f "$p" && sudo -n test ! -L "$p" || exit 1; row=$(sudo -n sha256sum "$p") || exit 1; v="$v$row\n"; done; a="$sd/authorized_clients"; if sudo -n test -e "$a"; then sudo -n test -d "$a" && sudo -n test ! -L "$a" || exit 1; members=$(sudo -n find "$a" -mindepth 1 -print) || exit 1; while IFS= read -r p; do [ -n "$p" ] || continue; sudo -n test -f "$p" && sudo -n test ! -L "$p" || exit 1; row=$(sudo -n sha256sum "$p") || exit 1; v="$v$row\n"; done <<<"$members"; elif ! sudo -n test ! -e "$a"; then exit 1; fi; done; [ -n "$v" ] || exit 1; printf "%b" "$v" | sort | sha256sum | cut -d" " -f1')" || return 1
    [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'onion-files=%s\n' "$fp"
}

candidate_compose_refs() {
    local cfg candidate_version
    candidate_version="$(tr -d '\n' <"$UPGRADE_STAGE_DIR/pithead/VERSION")"
    cfg="$(STACK_VERSION="$candidate_version" docker compose --project-directory "$UPGRADE_STAGE_DIR/pithead" \
        --env-file "$IT_REMOTE_DIR/.env" -f "$UPGRADE_STAGE_DIR/pithead/docker-compose.yml" \
        config --format json 2>/dev/null)" || return 1
    jq -r '.services | to_entries[] | select(.value.image) | [.key,.value.image] | @tsv' <<<"$cfg" | sort
}

all_refs_pinned() {
    local name ref seen=0
    while read -r name ref; do
        [ -n "$name" ] && [[ "$ref" =~ @sha256:[0-9a-f]{64}$ ]] || return 1
        seen=1
    done <<<"$1"
    [ "$seen" = 1 ]
}

candidate_refs_for_running_set() { # <running service/ref lines>
    local service _ref candidate
    while read -r service _ref; do
        candidate="$(awk -v s="$service" '$1==s {print $2}' <<<"$UPGRADE_CANDIDATE_ALL_REFS")"
        [ -n "$candidate" ] || return 1
        printf '%s %s\n' "$service" "$candidate"
    done <<<"$1"
}

ensure_cosign_image() {
    docker image inspect "$LIVE_COSIGN_IMAGE" >/dev/null 2>&1 ||
        docker pull -q "$LIVE_COSIGN_IMAGE" >/dev/null 2>&1
}

run_trusted_cosign() {
    ensure_cosign_image || return 1
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$UPGRADE_TRUSTED_KEY:/trusted.pub:ro" "$LIVE_COSIGN_IMAGE" "$@"
}

extract_candidate_archive() { # <snapshot.tar.gz> <private-stage>
    python3 - "$1" "$2" <<'PY'
import pathlib
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as archive:
    seen = set()
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if (not path.parts or path.is_absolute() or ".." in path.parts or
                path.parts[0] != "pithead" or member.name in seen or
                not (member.isfile() or member.isdir())):
            raise SystemExit("unsafe candidate archive member")
        seen.add(member.name)
    archive.extractall(sys.argv[2])
PY
}

prepare_candidate_bundle() {
    local _service ref revision service line candidate_commit
    UPGRADE_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pithead-live-candidate.XXXXXX")" || return 1
    chmod 700 "$UPGRADE_STAGE_DIR" || return 1
    UPGRADE_BUNDLE_SNAPSHOT="$UPGRADE_STAGE_DIR/candidate.tar.gz"
    UPGRADE_SIGNATURE_SNAPSHOT="$UPGRADE_STAGE_DIR/candidate.sig"
    UPGRADE_TRUSTED_KEY="$UPGRADE_STAGE_DIR/trusted.pub"
    (umask 077 && cp "$CANDIDATE_BUNDLE" "$UPGRADE_BUNDLE_SNAPSHOT" &&
        cp "$CANDIDATE_SIGNATURE" "$UPGRADE_SIGNATURE_SNAPSHOT" &&
        cp "$TRUSTED_COSIGN_PUB" "$UPGRADE_TRUSTED_KEY") || return 1
    chmod 400 "$UPGRADE_BUNDLE_SNAPSHOT" "$UPGRADE_SIGNATURE_SNAPSHOT" "$UPGRADE_TRUSTED_KEY" || return 1
    ensure_cosign_image || return 1
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$UPGRADE_TRUSTED_KEY:/trusted.pub:ro" -v "$UPGRADE_BUNDLE_SNAPSHOT:/candidate.tar.gz:ro" \
        -v "$UPGRADE_SIGNATURE_SNAPSHOT:/candidate.sig:ro" "$LIVE_COSIGN_IMAGE" verify-blob --key /trusted.pub \
        --signature /candidate.sig --insecure-ignore-tlog=true /candidate.tar.gz >/dev/null 2>&1 || return 1
    extract_candidate_archive "$UPGRADE_BUNDLE_SNAPSHOT" "$UPGRADE_STAGE_DIR" || return 1
    [ -x "$UPGRADE_STAGE_DIR/pithead/pithead" ] &&
        [ -f "$UPGRADE_STAGE_DIR/pithead/docker-compose.yml" ] &&
        [ -f "$UPGRADE_STAGE_DIR/pithead/cosign.pub" ] &&
        [ -f "$UPGRADE_STAGE_DIR/pithead/PITHEAD_COMMIT" ] &&
        [ -z "$(find "$UPGRADE_STAGE_DIR/pithead" -type l -print -quit)" ] || return 1
    cmp -s "$UPGRADE_TRUSTED_KEY" "$UPGRADE_STAGE_DIR/pithead/cosign.pub" || return 1
    candidate_commit="$(tr -d '\n' <"$UPGRADE_STAGE_DIR/pithead/PITHEAD_COMMIT")"
    valid_full_sha "$candidate_commit" && [ "$candidate_commit" = "$IMAGE_UPGRADE_TO_SHA" ] || return 1
    UPGRADE_CANDIDATE_ALL_REFS="$(candidate_compose_refs)" || return 1
    all_refs_pinned "$UPGRADE_CANDIDATE_ALL_REFS" || return 1
    UPGRADE_CANDIDATE_REFS="$({
        for service in tor monerod p2pool xmrig-proxy dashboard; do
            line="$(awk -v s="$service" '$1==s {print}' <<<"$UPGRADE_CANDIDATE_ALL_REFS")"
            [ -n "$line" ] || exit 1
            printf '%s\n' "$line"
        done
    })" || return 1
    pinned_refs_valid "$UPGRADE_CANDIDATE_REFS" || return 1
    while read -r _service ref; do
        run_trusted_cosign verify --key /trusted.pub --private-infrastructure "$ref" >/dev/null 2>&1 || return 1
        docker pull -q "$ref" >/dev/null 2>&1 || return 1
        revision="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$ref" 2>/dev/null)"
        revision_matches_sha "$revision" "$IMAGE_UPGRADE_TO_SHA" || return 1
    done <<<"$UPGRADE_CANDIDATE_REFS"
}

prepare_baseline_install() {
    local parent old_name
    UPGRADE_BASELINE_DIR="$(rx 'pwd -P')" || return 1
    parent="$(dirname "$UPGRADE_BASELINE_DIR")" old_name="$(basename "$UPGRADE_BASELINE_DIR")"
    [[ "$old_name" == pithead-v* ]] || return 1
    UPGRADE_CURRENT_LINK="$parent/current"
    [ "$(readlink -f "$UPGRADE_CURRENT_LINK")" = "$UPGRADE_BASELINE_DIR" ] || return 1
    UPGRADE_ROLLBACK_DIR="$UPGRADE_BASELINE_DIR"
}

prepare_candidate_install() {
    local version parent sdir
    [ -n "$UPGRADE_BASELINE_DIR" ] && [ -n "$UPGRADE_CURRENT_LINK" ] || return 1
    parent="$(dirname "$UPGRADE_BASELINE_DIR")"
    version="$(tr -d '\n' <"$UPGRADE_STAGE_DIR/pithead/VERSION")"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    UPGRADE_CANDIDATE_DIR="$parent/pithead-v$version"
    [ ! -e "$UPGRADE_CANDIDATE_DIR" ] && [ ! -L "$UPGRADE_CANDIDATE_DIR" ] || return 1
    mkdir "$UPGRADE_CANDIDATE_DIR" || return 1
    cp -a "$UPGRADE_STAGE_DIR/pithead/." "$UPGRADE_CANDIDATE_DIR/" || return 1
    cp -p "$UPGRADE_BASELINE_DIR/config.json" "$UPGRADE_BASELINE_DIR/.env" "$UPGRADE_CANDIDATE_DIR/" || return 1
    mkdir -p "$UPGRADE_CANDIDATE_DIR/data" || return 1
    for sdir in control clearnet-state caddy-logs; do
        [ ! -d "$UPGRADE_BASELINE_DIR/data/$sdir" ] || cp -a "$UPGRADE_BASELINE_DIR/data/$sdir" "$UPGRADE_CANDIDATE_DIR/data/" || return 1
    done
    IT_REMOTE_DIR="$UPGRADE_CANDIDATE_DIR"
}

repoint_baseline_install() {
    local tmp="${UPGRADE_CURRENT_LINK}.live-$$"
    ln -s "$(basename "$UPGRADE_BASELINE_DIR")" "$tmp" && mv -Tf "$tmp" "$UPGRADE_CURRENT_LINK"
}

restore_upgrade_baseline() {
    [ "$_UPGRADE_RESTORE_ARMED" = "1" ] || return 0
    _UPGRADE_RESTORE_ARMED=0
    it_warn "restoring the exact pre-upgrade release, state, and image set"
    local failed=0 files_ok=1 state restored_workers restored_telemetry monero_tip monero_height
    pithead down >/dev/null 2>&1 || {
        failed=1
        files_ok=0
    }
    IT_REMOTE_DIR="$UPGRADE_BASELINE_DIR"
    [ "$files_ok" = 0 ] || repoint_baseline_install || {
        failed=1
        files_ok=0
    }
    if [ "$files_ok" = 1 ]; then
        pithead restore -y "$SAFETY_ARCHIVE" >/dev/null 2>&1 || {
            failed=1
            files_ok=0
        }
        pithead down >/dev/null 2>&1 || {
            failed=1
            files_ok=0
        }
        if [ "$files_ok" = 1 ] && ! restore_state_snapshots; then
            failed=1
            files_ok=0
        fi
    fi
    if [ "$files_ok" = 1 ]; then
        if ! reset_control_units_for_render || ! pithead render >/dev/null 2>&1 ||
            ! strict_pithead up >/dev/null 2>&1 || ! wait_status_ok 300 ||
            ! wait_for 240 5 "the exact baseline worker set" _pred_worker_set "$UPGRADE_BEFORE_WORKERS"; then
            failed=1
        fi
    fi
    [ "$(rx 'cat config.json' 2>/dev/null)" = "$BASELINE_CONFIG" ] || failed=1
    [ "$(upgrade_secret_fingerprints)" = "$UPGRADE_BEFORE_SECRETS" ] || failed=1
    [ "$(derived_state_fingerprint)" = "$UPGRADE_BEFORE_DERIVED" ] || failed=1
    [ "$(all_running_refs)" = "$UPGRADE_BEFORE_REFS" ] || failed=1
    [ "$(first_party_revisions)" = "$UPGRADE_BEFORE_REVISIONS" ] || failed=1
    state="$(api_state)"
    [ "$(jq_get "$state" '.sync.monero.state')" = "done" ] || failed=1
    [ "$(jq_get "$state" '.sync.tari.state')" = "done" ] || failed=1
    monero_tip="$(monero_chain_tip)"
    monero_height="${monero_tip%% *}"
    chain_tip_valid "$monero_tip" && height_continues "$UPGRADE_BEFORE_MONERO" "$monero_height" || failed=1
    height_continues "$UPGRADE_BEFORE_TARI" "$(jq_get "$state" '.sync.tari.current')" || failed=1
    [ "$(monero_block_identity "$((UPGRADE_BEFORE_MONERO - 1))")" = "$UPGRADE_BEFORE_MONERO_ID" ] || failed=1
    [ "$(tari_block_identity "$UPGRADE_BEFORE_TARI")" = "$UPGRADE_BEFORE_TARI_ID" ] || failed=1
    [ "$(stateful_mounts)" = "$UPGRADE_BEFORE_MOUNTS" ] || failed=1
    restored_workers="$(worker_names)"
    [ "$restored_workers" = "$UPGRADE_BEFORE_WORKERS" ] || failed=1
    [ "$(jq_get "$state" '.proxy_workers')" -ge "$EXPECTED_WORKERS" ] 2>/dev/null || failed=1
    [ "$(jq_get "$state" '.stratum.total_hashes')" -gt 0 ] 2>/dev/null || failed=1
    restored_telemetry="$(dashboard_durable_rows "$UPGRADE_TELEMETRY_EPOCH")"
    telemetry_rows_continue "$UPGRADE_BEFORE_TELEMETRY" "$restored_telemetry" || failed=1
    if [ "$failed" != 0 ]; then
        pithead down >/dev/null 2>&1 || true
        # shellcheck disable=SC2034 # consumed by run.sh:safety_cleanup after this sourced file returns
        SAFETY_RESTORE_FAILED=1
        _SAFETY_RESTORE_ARMED=0
        it_fail "exact pre-upgrade release baseline restored" \
            "code, state, health, config, secrets, images, chains, mounts, workers, or mining differ; recovery trees retained at $UPGRADE_ROLLBACK_DIR and $SAFETY_ARCHIVE"
        return 1
    fi
    it_pass "exact pre-upgrade release baseline restored"
    _XVB_RESTORE_ARMED=0
    _SAFETY_RESTORE_ARMED=0
    cleanup_state_snapshots
    rm -rf "$UPGRADE_STAGE_DIR" "$UPGRADE_CANDIDATE_DIR"
}

upgrade_abort_restore() {
    local original_rc=$? restore_failed=0
    if [ "$_UPGRADE_RESTORE_ARMED" = "1" ]; then
        restore_upgrade_baseline || restore_failed=1
    fi
    [ -z "$_UPGRADE_FOREIGN_TRAP" ] || eval "$_UPGRADE_FOREIGN_TRAP"
    [ "$restore_failed" = 0 ] || exit 1
    return "$original_rc"
}

arm_upgrade_abort_restore() {
    local cur
    cur="$(trap -p EXIT)"
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _UPGRADE_FOREIGN_TRAP="${parsed[2]}"
    fi
    _UPGRADE_RESTORE_ARMED=1
    trap upgrade_abort_restore EXIT
}

dashboard_durable_rows() { # <fixed capture epoch>
    local payload
    payload="$(base64 <"$HERE/lib/migration-state-probe.py" | tr -d '\n')"
    rx "printf %s $(quote_arg "$payload") | base64 -d | docker exec -i dashboard python3 - --require-current-schema $(quote_arg "$1")" 2>/dev/null
}

archived_dashboard_durable_rows() { # <archive> <fixed capture epoch>
    local payload
    payload="$(base64 <"$HERE/lib/migration-state-probe.py" | tr -d '\n')"
    rx "d=\$(mktemp -d); cleanup() { rm -rf \"\$d\"; }; trap cleanup EXIT; member=\$(tar -tzf $(quote_arg "$1") | grep '/mining_data.db$'); [ \$(printf '%s\\n' \"\$member\" | grep -c .) = 1 ] && tar -xOf $(quote_arg "$1") \"\$member\" >\"\$d/db\" && printf %s $(quote_arg "$payload") | base64 -d | python3 - $(quote_arg "$2") \"\$d/db\"" 2>/dev/null
}

telemetry_rows_continue() { # <before-lines> <after-lines>
    [ -n "$1" ] && [ -z "$(comm -23 <(printf '%s\n' "$1" | sort) <(printf '%s\n' "$2" | sort))" ]
}

proxy_active_route() {
    rx "docker exec dashboard python3 -c 'import json;from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient;from mining_dashboard.config.config import PROXY_HOST,PROXY_API_PORT,PROXY_AUTH_TOKEN;c=XMRigProxyClient(PROXY_HOST,PROXY_API_PORT,PROXY_AUTH_TOKEN).get_config();p=next((p for p in c.get(\"pools\",[]) if p.get(\"enabled\")),{});print(json.dumps({\"url\":p.get(\"url\",\"\"),\"socks5\":p.get(\"socks5\",\"\")}))' 2>/dev/null"
}
proxy_active_pool() { proxy_active_route | jq -r '.url // empty' 2>/dev/null; }
proxy_active_socks5() { proxy_active_route | jq -r '.socks5 // empty' 2>/dev/null; }

_pred_proxy_route() { # <mode-substring> <active-pool-url>
    local st
    st="$(api_state)"
    [[ "$(jq_get "$st" '.hashrate.mode_name')" == *"$1"* ]] &&
        [ "$(proxy_active_pool)" = "$2" ] &&
        [ "$(jq_get "$st" '.proxy_workers')" -gt 0 ] 2>/dev/null
}

_pred_xvb_feed_fresh() {
    local st ts
    st="$(api_state)"
    ts="$(rx 'curl -fsS --max-time 8 http://127.0.0.1:8000/api/xvb-standby 2>/dev/null' | jq -r '(.ts // 0) | floor' 2>/dev/null)"
    [ "$(jq_get "$st" '.hashrate.xvb_stale')" = "false" ] &&
        [ "${ts:-0}" -gt "$XVB_FEED_TS_BEFORE" ] 2>/dev/null
}

_pred_xvb_routed_visible() {
    local st routed
    st="$(api_state)"
    routed="$(jq_get "$st" '.hashrate.xvb_routed_1h')"
    [[ "$(jq_get "$st" '.hashrate.mode_name')" == *XVB* ]] &&
        [ "$(jq_get "$st" '.shares_window.count')" -gt 0 ] 2>/dev/null &&
        [ -n "$routed" ] && [ "$routed" != "0.00 H/s" ]
}

monero_block_identity() { # <height>
    rx "docker exec dashboard python3 -c 'import requests,sys;from requests.auth import HTTPDigestAuth;from mining_dashboard.config.config import MONERO_NODE_PASSWORD,MONERO_NODE_USERNAME,MONERO_RPC_URL;a=HTTPDigestAuth(MONERO_NODE_USERNAME,MONERO_NODE_PASSWORD) if MONERO_NODE_USERNAME else None;r=requests.post(MONERO_RPC_URL.rstrip(\"/\")+\"/json_rpc\",auth=a,json={\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_block_header_by_height\",\"params\":{\"height\":int(sys.argv[1])}},timeout=8);r.raise_for_status();print(r.json()[\"result\"][\"block_header\"][\"hash\"])' $(quote_arg "$1")" 2>/dev/null
}

monero_chain_tip() {
    rx "docker exec dashboard python3 -c 'import requests;from requests.auth import HTTPDigestAuth;from mining_dashboard.config.config import MONERO_NODE_PASSWORD,MONERO_NODE_USERNAME,MONERO_RPC_URL;a=HTTPDigestAuth(MONERO_NODE_USERNAME,MONERO_NODE_PASSWORD) if MONERO_NODE_USERNAME else None;r=requests.get(MONERO_RPC_URL.rstrip(\"/\")+\"/get_info\",auth=a,timeout=8);r.raise_for_status();v=r.json();print(v[\"height\"],v[\"top_block_hash\"])'" 2>/dev/null
}

chain_tip_valid() { [[ "${1:-}" =~ ^[1-9][0-9]*\ [0-9a-f]{64}$ ]]; }

tari_block_identity() { # <height>
    rx "docker exec dashboard python3 -c 'import grpc,sys;from mining_dashboard.config.config import TARI_GRPC_ADDRESS;from mining_dashboard.client.tari.generated import base_node_pb2,base_node_pb2_grpc;s=base_node_pb2_grpc.BaseNodeStub(grpc.insecure_channel(TARI_GRPC_ADDRESS));h=next(s.ListHeaders(base_node_pb2.ListHeadersRequest(from_height=int(sys.argv[1]),num_headers=1,sorting=base_node_pb2.SORTING_ASC),timeout=8)).header;print(h.height,h.hash.hex())' $(quote_arg "$1")" 2>/dev/null
}
