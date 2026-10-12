#!/usr/bin/env bash
# Standalone local-node login edit and its coupled runtime verdict (#2333, #3220). Sourced by appliance-node-runtime-leg.sh; needs the shared approval helpers.

# shellcheck disable=SC2034 # LOCAL_NODE_LOGIN_* are read by the sourcing leg
# Input: `podman inspect monerod dashboard p2pool`; $cfg: config.json. Podman's .Name carries no leading slash (Docker's does), so accept both rather than silently match nothing.
# shellcheck disable=SC2016 # jq program, not shell
LOCAL_NODE_LOGIN_JQ='($cfg[0].monero.node_username // "") as $u | ($cfg[0].monero.node_password // "") as $p |
    def container($name): map(select((.Name | ltrimstr("/")) == $name))[0];
    def has_login($name): container($name).Config.Env |
        index("MONERO_NODE_USERNAME=" + $u) != null and index("MONERO_NODE_PASSWORD=" + $p) != null;
    (container("p2pool").Config.Cmd) as $cmd | ($cmd | index("--rpc-login")) as $i |
    $u != "" and $p != "" and has_login("monerod") and has_login("dashboard") and
    $i != null and $cmd[$i+1] == ($u + ":" + $p)'
LOCAL_NODE_LOGIN_REASON="not-run"

local_node_login_runtime_verdict() {
    local jq_q
    printf -v jq_q %q "$(printf '%s' "$LOCAL_NODE_LOGIN_JQ" | tr '\n' ' ')" # one line: no $'' quoting
    _ssh "podman inspect monerod dashboard p2pool | jq -e --slurpfile cfg /data/pithead/config.json $jq_q >/dev/null"
}

# Value-free account of a failed verdict: which component disagreed with config (ok/stale/missing, never a value) and the
# container epochs (Id prefix + StartedAt), so a stale snapshot, a wrong field and a failed inspect read differently.
# shellcheck disable=SC2016 # jq program, not shell
LOCAL_NODE_LOGIN_DIAG_JQ='($cfg[0].monero.node_username // "") as $u | ($cfg[0].monero.node_password // "") as $p |
    def container($name): map(select((.Name | ltrimstr("/")) == $name))[0];
    def login($name): container($name).Config.Env as $e |
        if $e == null then "missing" elif ($e | index("MONERO_NODE_USERNAME=" + $u) != null) and ($e | index("MONERO_NODE_PASSWORD=" + $p) != null) then "ok" else "stale" end;
    def epoch($name): container($name) | ((.Id // "")[0:12]) + "@" + (.State.StartedAt // "unknown");
    (container("p2pool").Config.Cmd) as $cmd | ($cmd | index("--rpc-login")) as $i |
    "monerod_env=\(login("monerod")) dashboard_env=\(login("dashboard")) p2pool_rpc_login=\(if $i == null then "missing" elif $cmd[$i+1] == ($u + ":" + $p) then "ok" else "stale" end) config_login=\(if $u != "" and $p != "" then "set" else "empty" end) epoch monerod=\(epoch("monerod")) dashboard=\(epoch("dashboard")) p2pool=\(epoch("p2pool"))"'

local_node_login_diagnostics() {
    local jq_q out
    printf -v jq_q %q "$(printf '%s' "$LOCAL_NODE_LOGIN_DIAG_JQ" | tr '\n' ' ')"
    out=$(_ssh "podman inspect monerod dashboard p2pool | jq -r --slurpfile cfg /data/pithead/config.json $jq_q" 2>/dev/null) &&
        [ -n "$out" ] || out="inspect-failed"
    printf '%s' "$out" | head -c 400
}

local_node_login_edit() { # <config-path> <env-key> <value> <label>
    local live proposed preview result rid
    LOCAL_NODE_LOGIN_DIAG=""
    LOCAL_NODE_LOGIN_REASON="live-config-unreadable"
    live=$(sensitive_live_config) || return 1
    LOCAL_NODE_LOGIN_REASON="proposal-unbuildable"
    proposed=$(printf '%s' "$live" | jq -c --arg value "$3" "$1 = \$value") || return 1
    LOCAL_NODE_LOGIN_REASON="preview-failed"
    sensitive_preview "$(dashboard_config_body "$proposed")" || return 1
    preview=$APPROVAL_PREVIEW rid=$APPROVAL_REQUEST_ID
    LOCAL_NODE_LOGIN_REASON="preview-not-confirm-gated"
    printf '%s' "$preview" | jq -e --arg key "$2" \
        '.status == "previewed" and .destructive == true and any(.changes[]?; .key == $key and .flag == "CONFIRM")' >/dev/null || return 1
    result=$(approval_commit "$rid")
    LOCAL_NODE_LOGIN_REASON="commit-$(printf '%s' "$result" | jq -r '.status // "unreadable"' 2>/dev/null || printf unreadable)"
    printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null || return 1
    LOCAL_NODE_LOGIN_REASON="dashboard-unreadable-after-apply"
    sensitive_live_config >/dev/null || return 1
    LOCAL_NODE_LOGIN_REASON="runtime-login-mismatch"
    local_node_login_runtime_verdict || {
        LOCAL_NODE_LOGIN_DIAG=$(local_node_login_diagnostics)
        return 1
    }
    LOCAL_NODE_LOGIN_REASON="ok"
    ok "standalone local $4 preserves the coupled node login and authenticated dashboard access"
}

# The real verdict against a fake podman's inspect JSON (.Name without Docker's leading slash).
_local_node_login_self_test() (
    local tmp login
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "$tmp"' EXIT
    printf '{"monero":{"node_username":"u1","node_password":"p1"}}' >"$tmp/config.json"
    login=u1:p1
    _ssh() { PATH="$tmp:$PATH" bash -c "${1//\/data\/pithead\/config.json/$tmp/config.json}"; }
    write_podman() {
        printf '#!/bin/sh\ncat <<EOF\n[{"Name":"monerod","Id":"abc123def456789","State":{"StartedAt":"t1"},"Config":{"Env":["MONERO_NODE_USERNAME=u1","MONERO_NODE_PASSWORD=p1"],"Cmd":[]}},{"Name":"dashboard","Config":{"Env":["MONERO_NODE_USERNAME=u1","MONERO_NODE_PASSWORD=p1"],"Cmd":[]}},{"Name":"p2pool","Config":{"Env":[],"Cmd":["--rpc-login","%s"]}}]\nEOF\n' "$1" >"$tmp/podman"
        chmod +x "$tmp/podman"
    }
    write_podman "$login"
    local_node_login_runtime_verdict || return 1
    write_podman u1:stale
    ! local_node_login_runtime_verdict || return 1
    local diag
    diag=$(local_node_login_diagnostics)
    case "$diag" in *"monerod_env=ok dashboard_env=ok p2pool_rpc_login=stale config_login=set epoch monerod=abc123def456@t1"*) ;; *) return 1 ;; esac
    case "$diag" in *u1* | *p1*) return 1 ;; esac # value-free
    printf '#!/bin/sh\nexit 1\n' >"$tmp/podman"
    [ "$(local_node_login_diagnostics)" = inspect-failed ]
)
