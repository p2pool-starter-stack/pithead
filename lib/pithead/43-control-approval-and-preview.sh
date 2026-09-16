# The remedy half of a control-channel refusal (#1888, the #1821 class): "edit config.json and run
# apply" is a real remedy on a DIY host and a DEAD END on a shell-less appliance (#786).
_control_host_remedy() {
    if is_appliance; then
        printf 'That setting is not changeable from the dashboard on an appliance; it is fixed when the machine is set up, so use "Set up again" if you need to change it.'
    else
        printf 'Edit config.json on the host and run `%s apply`.' "$0"
    fi
}

control_approval_gate() { # <staged-file> [confirm-token] <id> <actor> [approval-json] <control-dir>
    local staged="$1" confirm="${2:-}" id="$3" actor="$4" approval="${5:-null}" cdir="$6" porcelain
    local approval_required=0 worker_sensitive=0 needs_confirm=0
    # Fail closed if we cannot re-derive the change set (the staged config was validated at
    # preview, so a dry-run failure here means something changed — refuse).
    if ! porcelain=$(PITHEAD_CONFIG_FILE="$staged" "$0" apply --dry-run --porcelain 2>/dev/null); then
        printf 'could not re-validate the staged change host-side — refusing to commit'
        return 1
    fi
    # A config.json block that never renders to .env emits ZERO porcelain rows, so each is handled
    # HERE by name. Worker descriptors confirm after their SSRF guard; dashboard.energy and
    # local_miner.enabled are ordinary, bar dashboard.energy.price_feed. A NEW one MUST add a line.
    #
    # The per-worker descriptors — workers.list[] (#506) — carry per-rig hosts and API tokens
    # (exactly the "free-form string that reaches a URL or credential" class the allowlist exists to
    # keep host-CLI-only). The deprecated dashboard.workers[] alias (#172) used to be refused here
    # outright; 2.0.0 removed it (#1832), so a staged config carrying it is now refused one step
    # later by the closed-schema check below, as an unknown key like any other typo.
    #
    # Every descriptor change is sensitive: an append introduces a new remote host and token;
    # repointing or reordering changes an existing trust relationship. #1959 moves it behind the
    # same typed confirmation as the other sensitive settings, after the SSRF floor below.
    if ! jq -e --slurpfile live "$CONFIG_FILE" '
        (.workers.list // []) == ($live[0].workers.list // [])
        ' "$staged" >/dev/null 2>&1; then
        worker_sensitive=1
    fi
    # SSRF floor on worker hosts (see _control_host_is_internal). For an unchanged list there is
    # nothing to inspect. For any changed list, validate every staged host so modification and append
    # cannot smuggle a host inside this machine's own network.
    local live_n new_host
    live_n=$(jq -r --slurpfile live "$CONFIG_FILE" '($live[0].workers.list // []) | length' "$staged" 2>/dev/null) || live_n=0
    [ "$worker_sensitive" -eq 1 ] && live_n=0
    while IFS= read -r new_host; do
        [ -n "$new_host" ] || continue
        if _control_host_is_internal "$new_host"; then
            printf 'a new worker descriptor points at %s, which resolves inside this host'"'"'s own network — a rig'"'"'s control address must be a distinct machine on your LAN, not this host or one of its own containers.' "$new_host"
            return 1
        fi
    done < <(jq -r --argjson n "${live_n:-0}" '(.workers.list // [])[$n:] | .[] | select(has("host")) | .host' "$staged" 2>/dev/null)
    # Closed-schema guard (#33 hardening). A config.json key the stack doesn't recognize renders to
    # NO env var, so it emits zero porcelain rows and slips past the allowlist below — yet the
    # commit's `cp "$staged" "$CONFIG_FILE"` would still persist it. So refuse any staged path that
    # isn't in the canonical schema (config.reference.json). Numeric path components are dropped so a
    # populated known scalar array (notifications.webhooks) collapses
    # onto its schema-listed key instead of false-rejecting, while a smuggled OBJECT inside such an
    # array still surfaces its unknown sub-key. Both worker-descriptor shapes are exempt: their
    # per-rig object elements aren't enumerated in the reference and the array is already fully
    # guarded above. Fail closed — an unreadable reference or a jq error refuses the commit.
    # INVARIANT: config.reference.json MUST stay a complete superset of every config path this script
    # reads (grep the config_bool/`jq ... "$CONFIG_FILE"` sites), or a legit config carrying a
    # read-but-unlisted path is false-rejected on every commit. 2.0.0 removed the two backward-compat
    # aliases that used to need listing for this reason (#1832), so the superset is now smaller rather
    # than larger. Guarded two ways in tests/stack/run.sh: the case asserting a staged 1.x alias is
    # REFUSED here rather than round-tripped, and (#561) an automated drift guard that walks this
    # script's own config_bool/`jq ... "$CONFIG_FILE"` read sites with a conservative fixed-shape
    # extractor and fails loud ("extend the extractor") on a shape it doesn't recognize, rather than
    # risking the false-alarms a naive grep-based path diff would hit on jq-internal and filename
    # dotted tokens.
    local unknown
    if ! unknown=$(jq -rn --slurpfile ref "$REFERENCE_CONFIG" --slurpfile cfg "$staged" '
        def norm: [.[] | strings] | join(".");
        ([$cfg[0] | paths | select(.[0:2] != ["workers", "list"]) | norm]
         - [$ref[0] | paths | norm])
        | unique | join(", ")' 2>/dev/null); then
        printf 'could not validate the staged config against the schema (%s) — refusing to commit' "$REFERENCE_CONFIG"
        return 1
    fi
    if [ -n "$unknown" ]; then
        printf 'this change adds config keys not in the schema (%s) — refusing to commit. %s' "$unknown" "$(_control_host_remedy)"
        return 1
    fi
    # Every unlisted schema-backed env change joins the typed confirmation tier (#1959).
    local committable_re approval_re bad hit
    committable_re=$(control_committable_re)
    bad=$(printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -cvxE "$committable_re" || true)
    if control_never_path_changed "$staged"; then
        printf 'this change includes a physical-presence-only setting and cannot be made from the dashboard; use a configuration stick'
        return 1
    fi
    if [ "${bad:-0}" -gt 0 ]; then
        approval_required=1
        needs_confirm=1
    fi
    if control_changed_config_paths "$staged" | grep -qxF "$CONTROL_DASHBOARD_APPROVAL_PATHS"; then approval_required=1; fi
    if control_changed_config_paths "$staged" | grep -qxF -e "$CONTROL_DASHBOARD_APPROVAL_PATHS" -e "$CONTROL_DASHBOARD_CONFIRM_PATHS"; then needs_confirm=1; fi
    if [ "$worker_sensitive" -eq 1 ]; then
        approval_required=1
        needs_confirm=1
    fi
    approval_re=$(printf '%s' "$CONTROL_DASHBOARD_APPROVAL_KEYS" | tr -s ' \n' '|' | sed 's/^|*//;s/|*$//')
    [ -n "$approval_re" ] && printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -qxE "$approval_re" && approval_required=1
    printf '%s\n' "$porcelain" | grep -qE $'^DEST\t' && approval_required=1
    # Electricity price feeds are remote control inputs, unlike the local display currency and
    # fixed-price values beside them. They join the same sensitive class even though dashboard.energy
    # is config.json-only and therefore has no porcelain row.
    if control_changed_config_paths "$staged" | grep -qx 'dashboard.energy.price_feed'; then
        approval_required=1
    fi
    # Host-shell data paths use a catastrophic-root blocklist; dashboard moves use the tighter
    # allowlist and symlink boundary because a confirmed commit later mkdir/chown's as root.
    control_validate_data_dir_destinations "$staged" || return 1
    # Confirm-gate (#719): an in-scope CONFIRM row PROCEEDS only with the operator's typed
    # confirmation. The token is a fixed literal ("APPLY"), orthogonal to the value being set — it
    # is friction that forces the operator to acknowledge an expensive/disruptive op, NOT a security
    # control (the perimeter above is the boundary). control_commit records a confirmed change
    # distinctly in the audit log via the marker file touched here.
    printf '%s\n' "$porcelain" | grep -qE $'^(CONFIRM|DEST)\t' && needs_confirm=1
    if [ "$needs_confirm" -eq 1 ]; then
        if [ "$confirm" != "APPLY" ]; then
            hit=$(printf '%s\n' "$porcelain" | grep -m1 -E $'^CONFIRM\t' | cut -f3-)
            printf 'this change is disruptive (%s) — type APPLY in the dashboard to confirm.' "${hit:-disruptive change}"
            return 1
        fi
        touch "${staged}.confirmed" 2>/dev/null || true
    fi
    # Reachability probe (#1888) — the compensating control the confirm tier rests on for these keys
    # (42-): the typed token is friction, but a chain cannot be parked on a node that is not there.
    # Host-side, on the STAGED config, through the same preflight the wizard uses; nothing is
    # trusted from the container. Fires only when a node-endpoint key really changed (so an
    # unrelated commit is never blocked by a node that is down) and only after the typed
    # confirmation (so an unconfirmed attempt never pays the dial timeouts).
    local probe_err endpoint_re
    endpoint_re=$(printf '%s' "$CONTROL_NODE_ENDPOINT_KEYS" | tr -s ' \n' '|')
    if printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -qxE "$endpoint_re"; then
        if ! probe_err=$(preflight_remote_nodes "$staged" 2>/dev/null); then
            printf 'this change points the stack at a node the host cannot use: %s' "$probe_err"
            return 1
        fi
    fi
    # Typed payout confirmation, checked after physical-presence, typed-confirmation and endpoint
    # reachability checks have passed.
    if [ "$approval_required" -eq 1 ]; then
        local reason
        if ! reason=$(control_validate_approval "$staged" "$actor" "$approval" "$porcelain"); then
            [ -n "$reason" ] && printf '%s' "$reason"
            return 1
        fi
    fi
    # Permitted: echo the changed key NAMES so the commit's audit entry can record WHAT changed
    # (#349) without a third dry-run. Names only, never values. dashboard.energy (#504) is
    # config.json-only, so it never appears in the env porcelain — include the changed
    # dashboard.energy.* paths directly, else an energy-only commit would audit no key.
    # Reference defaults merged into both sides (#696), same as the preview leg: the editor
    # round-trips the reference-merged form, and materialized defaults are not a change.
    {
        control_changed_config_paths "$staged"
        [ "$worker_sensitive" -eq 1 ] && printf '%s\n' 'workers.list'
    } | sort -u | tr '\n' ' ' | sed 's/ $//'
    return 0
}

# Preview: stage the candidate config host-side, dry-run it, report the describe_change rows.
control_preview() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local staged="$cdir/staged/$id.json" errf="$cdir/staged/.$id.err" out result
    if [ "$(jq -r '.config | type' "$file")" != "object" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"config must be a JSON object",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    # A masked worker token may survive an ordinary round-trip, but never an endpoint repoint.
    # Restoring the old bearer by name after host/port/control_port changed would send a secret the
    # container never knew to a destination it chose. Make the operator provide the replacement.
    if ! jq -e --slurpfile live "$CONFIG_FILE" '
        def endpoint($api_port): [(.host // null), (.port // $api_port), (.control_port // 8082)];
        (reduce (($live[0].workers.list // []) | reverse | .[]) as $w ({};
            if ($w | type) == "object" and ($w.name | type) == "string"
            then .[$w.name] = $w else . end)) as $live_workers
        | [(.config.workers.api_port // 8080), ($live[0].workers.api_port // 8080)] as [$candidate_api_port, $live_api_port]
        | all(.config.workers.list[]?;
            if (.token | type) == "object" and .token.__secret__ == true
            then (.name | type) == "string"
              and ($live_workers[.name] | type) == "object"
              and endpoint($candidate_api_port) == ($live_workers[.name] | endpoint($live_api_port))
            else true end)' "$file" >/dev/null 2>&1; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"a worker endpoint changed while its token was masked — enter the token for the new endpoint explicitly",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    local binding_error
    if ! binding_error=$(control_masked_binding_error "$file"); then
        binding_error="could not verify masked secrets against their destinations"
    fi
    if [ -n "$binding_error" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$binding_error" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    # The "blank secret keeps the live value" merge happens HERE, host-side (#440): the request
    # arrives with {"__secret__":true} sentinels for secrets hidden from the editor/browser, and
    # each sentinel is swapped for the live config.json value at staging. A sentinel for a secret
    # that is not actually set
    # collapses to "" rather than leaking a dict into config.json. The staged copy therefore
    # carries merged secrets: it lives in host-only staged/ — never mounted — and is pinned
    # owner-only so a co-tenant on the host can't read secrets from it (#33 hardening). Created
    # under umask 077 so it is never even briefly world-readable (create-then-chmod race); the
    # chmod stays as belt-and-suspenders.
    # Per-worker token sentinels (#172) get the same swap, but out of the fixed-path walk: they
    # live in the variable-length descriptor array at workers.list[] (#506) — so restore each from
    # the LIVE token matched by worker name (first-declared wins on duplicate names, matching the
    # container's probe). The endpoint guard above rejects a sentinel without a same-name live
    # descriptor or with a changed host/port/control_port, before any bearer can be restored.
    # Webhook sentinels are positional because their order is their only stable identity.
    # dashboard.workers[] is restored too, and MUST be: 30's masker still masks that shape after
    # 2.0.0 removed the alias (#1832, see the note there), and mask and restore are one mechanism.
    # Keeping the mask without the restore would let a sentinel be committed as a literal token.
    # The LIVE lookup below therefore reads BOTH shapes, and that is the whole point: worker_list is
    # workers.list[] alone since #1832, so resolving legacy sentinels against it would find nothing
    # and blank every per-rig token to "" — a restore branch that cannot restore. workers.list[]
    # wins a name present in both (it is the canonical key, and both-populated-and-different is
    # already refused at apply); within one shape, first-declared still wins via the reverse.
    (umask 077 && jq --argjson paths "$CONTROL_SECRET_PATHS" --slurpfile live "$CONFIG_FILE" "$WORKER_LIST_JQ"'
        (reduce (($live[0] | worker_list) + (($live[0].dashboard // {}) | .workers // []) | reverse | .[]) as $w ({};
            if ($w | type) == "object" and ($w.name | type) == "string"
            then .[$w.name] = ($w.token // "") else . end)) as $livetok
        | reduce $paths[] as $p (.config;
            (try getpath($p) catch null) as $v
            | if ($v | type) == "object" and $v.__secret__ == true
              then setpath($p; (($live[0] | try getpath($p) catch null) // ""))
              else . end)
        | if (.workers | type) == "object" and (.workers.list | type) == "array"
          then .workers.list |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name] // "") else "" end)
              else . end)
          else . end
        | if (.notifications | type) == "object" and (.notifications.webhooks | type) == "array"
          then .notifications.webhooks |= (to_entries | map(
              if (.value | type) == "object" and .value.__secret__ == true
              then ($live[0].notifications.webhooks[.key] // "")
              else .value end))
          else . end
        | if (.dashboard | type) == "object" and (.dashboard.workers | type) == "array"
          then .dashboard.workers |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name] // "") else "" end)
              else . end)
          else . end' "$file" >"$staged")
    chmod 600 "$staged" 2>/dev/null || true
    if out=$(PITHEAD_CONFIG_FILE="$staged" "$0" apply --dry-run --porcelain 2>"$errf"); then
        # Unlisted reference values confirm; worker descriptor arrays join after their SSRF guard.
        local approval_required=false committable_re approval_re bad worker_changed=0 config_paths
        committable_re=$(control_committable_re)
        bad=$(printf '%s' "$out" | awk -F'\t' 'NF' | cut -f2 | grep -cvxE "$committable_re" || true)
        if ! jq -e --slurpfile live "$CONFIG_FILE" '(.workers.list // []) == ($live[0].workers.list // [])' "$staged" >/dev/null 2>&1; then
            worker_changed=1
        fi
        if control_never_path_changed "$staged"; then
            control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"this change includes a physical-presence-only setting; use a configuration stick",ts:(now|floor)}')"
            rm -f "$errf"
            control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
            return 0
        fi
        if [ "${bad:-0}" -gt 0 ]; then
            approval_required=true
            out=$(printf '%s\n' "$out" | awk -F'\t' -v re="$committable_re" '
                BEGIN {OFS=FS}
                NF && $2 !~ ("^(" re ")$") {$1="CONFIRM"}
                {print}')
        fi
        config_paths=$(control_changed_config_paths "$staged" | grep -xF -e "$CONTROL_DASHBOARD_APPROVAL_PATHS" -e "$CONTROL_DASHBOARD_CONFIRM_PATHS" || true)
        if [ -n "$config_paths" ]; then
            out=$(control_mark_config_confirm_rows "$config_paths" "$out")
            if printf '%s\n' "$config_paths" | grep -qxF "$CONTROL_DASHBOARD_APPROVAL_PATHS"; then approval_required=true; fi
        fi
        if [ "$worker_changed" -eq 1 ]; then
            approval_required=true
            out+="${out:+$'\n'}"$'CONFIRM\tworkers.list\tWorker descriptors (host, ports, credentials or membership) are changing.'
        fi
        approval_re=$(printf '%s' "$CONTROL_DASHBOARD_APPROVAL_KEYS" | tr -s ' \n' '|' | sed 's/^|*//;s/|*$//')
        if { [ -n "$approval_re" ] && printf '%s' "$out" | awk -F'\t' 'NF' | cut -f2 | grep -qxE "$approval_re"; } ||
            printf '%s\n' "$out" | grep -qE $'^DEST\t'; then
            approval_required=true
        fi
        result=$(printf '%s\n' "$out" | jq -R -s --argjson approval_required "$approval_required" \
            --argjson secret_paths "$CONTROL_SECRET_PATHS" --slurpfile ref "$REFERENCE_CONFIG" \
            --slurpfile live "$CONFIG_FILE" --slurpfile staged "$staged" '
            def dotted($p): $p | map(tostring) | join(".");
            def hidden($p):
              any($secret_paths[]; . == $p)
              or ($p[0:2] == ["workers","list"] and $p[-1] == "token")
              or $p[0:2] == ["notifications","webhooks"];
            ($ref[0] * $live[0]) as $live_full
            | ($ref[0] * $staged[0]) as $staged_full
            |
            [split("\n")[] | select(length > 0) | split("\t") | {flag: .[0], key: .[1], msg: (.[2:] | join("\t"))}]
            | {status: "previewed", changes: .,
               destructive: (map(.flag == "DEST" or .flag == "CONFIRM") | any),
               approval_required: $approval_required,
               preview_values: ((([$live_full | paths(type != "object" and type != "array")]
                   + [$staged_full | paths(type != "object" and type != "array")]) | unique) as $paths
                 | [$paths[] as $path
                   | select(hidden($path) | not)
                   | select(($live_full | getpath($path)) != ($staged_full | getpath($path)))
                   | {key:dotted($path), label:dotted($path),
                      old:($live_full | getpath($path)), new:($staged_full | getpath($path))}]),
               payout_confirmations: (reduce ["monero", "tari"][] as $c ({};
                 (($c + ".wallet_address") / ".") as $p
                 | if ($live[0] | getpath($p)) != ($staged[0] | getpath($p))
                   then .[$c] = (($staged[0] | getpath($p) // "") | if length > 8 then .[-8:] else . end)
                   else . end)),
               ts: (now | floor)}')
        # #504: dashboard.energy is config.json-only (never rendered to .env), so an energy-only
        # edit produces no porcelain row. Surface it as a normal committable INFO change so the UI
        # arms Apply and the commit lands it in config.json. The approval gate allowlists exactly
        # this config.json-only block; any OTHER config.json-only delta still refuses (see
        # control_approval_gate). INFO never flips destructive, so the existing verdict stands.
        # Compare with the reference defaults merged into BOTH sides (#696): the editor round-trips
        # the reference-merged form, so on a config.json that never set dashboard.energy the staged
        # copy carries the materialized defaults — an absent block and explicit defaults are the
        # same settings, not a change.
        if ! jq -e --slurpfile live "$CONFIG_FILE" --slurpfile ref "$REFERENCE_CONFIG" \
            '(($ref[0].dashboard.energy // {}) + ($live[0].dashboard.energy // {}))
             == (($ref[0].dashboard.energy // {}) + (.dashboard.energy // {}))' "$staged" >/dev/null 2>&1; then
            result=$(printf '%s' "$result" | jq '.changes += [{flag:"INFO",key:"dashboard.energy",msg:"Energy calculator settings (dashboard.energy) — electricity price / currency / XMR price updated."}]')
        fi
        if control_changed_config_paths "$staged" | grep -qx 'dashboard.energy.price_feed'; then
            result=$(printf '%s' "$result" | jq '.changes += [{flag:"APPROVAL",key:"dashboard.energy.price_feed",msg:"Electricity price feed endpoint changed — the host will contact this remote source for operating-cost data."}] | .approval_required = true')
        fi
        # local_miner.enabled (2026-09-13 perimeter audit round 2): also config.json-only, no
        # porcelain row. Ordinary like dashboard.energy — a documented dashboard toggle
        # (docs/workers.md), not a security control — but named explicitly rather than left
        # unaccounted for, which is the exact gap that let it bypass classification entirely.
        if ! jq -e --slurpfile live "$CONFIG_FILE" '(.local_miner.enabled // false) == ($live[0].local_miner.enabled // false)' "$staged" >/dev/null 2>&1; then
            result=$(printf '%s' "$result" | jq '.changes += [{flag:"INFO",key:"local_miner.enabled",msg:"The co-located local miner toggle changed."}]')
        fi
        control_write_result "$cdir/results" "$id" "$result"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "previewed" "$(porcelain_keys "$out")"
    else
        # Validation failed — reject with pithead's own error tail; nothing stays staged.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$errf")" '{status:"rejected",log:$e,ts:(now|floor)}')"
        rm -f "$staged"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
    fi
    rm -f "$errf"
}

# Hand the operator-facing stack files that the ROOT control-runner just wrote back to the stack
# owner (#33 v1.4). control_run_pending is root (User=root in pithead-control.service), so its
# `apply` renders `.env` under `umask 077` as root:root 0600 and rewrites the Caddyfile as root —
# but pithead runs a NON-ROOT operator model ($REAL_USER), and a normal operator-run apply leaves
# these files owned by the operator. Without this, the operator's next `status`/`apply` can't even
# read .env (Permission denied), which is what the tier-4 gate caught. The target owner is DERIVED
# from config.json's on-disk owner — an operator-owned file the dashboard container CANNOT write
# (its raw config.json mount was dropped in #440; control_commit's `cp` also preserves its inode/
# owner), so nothing from the request or spool can steer the chown. $USER/$SUDO_USER are NOT usable
# here — the runner is root, so they read as root. The control-dir (staged/results/audit) is
# deliberately host-owned and is NOT touched: that rw/ro split is the #33 trust boundary.
control_reown_operator_files() {
    local owner f
    # GNU stat first, BSD fallback (see the provision_onion_client_auth note). No owner → skip.
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    [ -n "$owner" ] || return 0
    # .bak-workers is the pre-2.0 name of the migration backup .bak-1x now writes (#1832) — both are
    # listed so a machine that migrated under 1.x still has its old copy reowned rather than stranded.
    for f in "$ENV_FILE" "Caddyfile" "${CONFIG_FILE}.bak-control" "${CONFIG_FILE}.bak-1x" "${CONFIG_FILE}.bak-workers"; do
        [ -e "$f" ] || continue
        # Fail safe: a chown that can't complete leaves the pre-existing bug, never corrupts state.
        chown "$owner" "$f" 2>/dev/null ||
            warn "Could not re-own $f to $owner after the control apply — the operator may need to chown it by hand."
    done
}

# Commit: apply the HOST-SIDE staged copy from the matching preview. A tampered second request
# can't swap the config — commit carries only the id; the config it applies is the one previewed.
control_commit() { # <id> <actor> <control-dir> [confirm-token] [approval-json]
    local id="$1" actor="$2" cdir="$3" confirm="${4:-}" approval="${5:-null}"
    local staged="$cdir/staged/$id.json" logf="$cdir/staged/.$id.log" rc=0
    if [ ! -f "$staged" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"no staged intent for this id — preview first",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    if [ -z "$(find "$staged" -mmin -10 2>/dev/null)" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"staged intent expired (older than 10 minutes) — preview again",ts:(now|floor)}')"
        rm -f "$staged"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    # On refusal the gate's stdout is the reason; on approval it is the changed key names, which
    # the audit entries below record — WHAT changed, by name only (#349).
    local gate_out audit_keys=""
    if ! gate_out=$(control_approval_gate "$staged" "$confirm" "$id" "$actor" "$approval" "$cdir"); then
        [ -n "$gate_out" ] || gate_out="approval denied"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$gate_out" '{status:"rejected",error:$e,ts:(now|floor)}')"
        rm -f "$staged" "${staged}.confirmed"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    audit_keys="$gate_out"
    # A confirm-gated destructive change (#719) is logged AS SUCH — the gate touches this marker
    # when a typed confirmation carried an in-scope CONFIRM row past the perimeter. The distinct
    # `commit-confirmed` action separates a dashboard-confirmed disruptive apply from an ordinary
    # (INFO-only) dashboard commit in the tamper-evidence log. Host-CLI applies never reach this log.
    # `approver` is retained as an audit FIELD so the log schema does not change under readers that
    # already parse it (and so historical `commit-approved` rows stay comparable), but nothing writes
    # it any more: the Telegram verifier was its only writer (#2076). It stays empty by construction.
    local audit_action="commit" approver=""
    if [ -f "${staged}.confirmed" ]; then
        audit_action="commit-confirmed"
        rm -f "${staged}.confirmed"
    fi
    # Keep a pre-change backup; on failure it is named in the result and left in place. The
    # `apply -y` below re-renders the pre-masked prefill copy (#440), so the dashboard's editor
    # form reflects the committed config on the next load.
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak-control"
    cp "$staged" "$CONFIG_FILE"
    "$0" apply -y >"$logf" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        control_reown_operator_files # the root apply wrote .env/Caddyfile as root — give them back (#33)
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"applied",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "applied" "$audit_keys" "$approver"
    else
        # apply's own .apply-incomplete marker handles the container-recreate retry; the config
        # backup lets the operator revert by hand if the new config itself is the problem.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" --arg b "${CONFIG_FILE}.bak-control" '{status:"failed",error:$e,backup:$b,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "failed" "$audit_keys" "$approver"
    fi
    rm -f "$staged" "$logf" "${staged}.confirmed"
}
