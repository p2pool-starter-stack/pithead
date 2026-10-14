control_approval_gate() { # <staged-file> [confirm-token] <id> <actor> [approval-json] <control-dir>
    local staged="$1" confirm="${2:-}" id="$3" actor="$4" approval="${5:-null}" cdir="$6" porcelain
    local approval_required=0 needs_confirm=0
    config_document_error "$CONFIG_FILE" || return 1
    config_document_error "$staged" || return 1
    control_policy_gate "$staged" || return 1
    # Re-derive the change set: a dry-run failure after preview refuses the commit.
    local carried_ssh=0
    control_carried_ssh "$staged" && carried_ssh=1
    if ! porcelain=$(PITHEAD_CONFIG_FILE="$staged" PITHEAD_CONFIG_CARRIED_SSH="$carried_ssh" "$0" apply --dry-run --porcelain 2>/dev/null); then
        printf 'could not re-validate the staged change host-side — refusing to commit'
        return 1
    fi
    # A config.json block that never renders to .env emits ZERO porcelain rows, so the default-deny
    # pass can neither see nor refuse it: each is handled HERE by name (worker descriptors below;
    # dashboard.energy and local_miner.enabled are ordinary, #504/2026-09-13 perimeter audit round
    # 2, bar dashboard.energy.price_feed). A NEW one MUST add its own line.
    #
    # workers.list[] (#506) carries per-rig hosts and API tokens; the removed dashboard.workers[]
    # alias (#1832) is refused by the closed-schema check below. control_worker_append (42-) allows
    # only an adopt (append) behind the typed APPLY and the #122 SSRF floor; a repoint, reorder or
    # removal is refused (#912 owns descriptor editing; #1959's confirm tier does not widen it).
    local worker_new
    if ! worker_new=$(control_worker_append "$staged"); then
        printf '%s' "$worker_new"
        return 1
    fi
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
    if ! unknown=$(jq -rn --argjson carried "$carried_ssh" --slurpfile ref "$REFERENCE_CONFIG" --slurpfile cfg "$staged" '
        def norm: [.[] | strings] | join(".");
        ([$cfg[0] | paths | select(($carried != 1 or .[0] != "ssh") and .[0:2] != ["workers", "list"]) | norm]
         - [$ref[0] | paths | norm])
        | unique | join(", ")' 2>/dev/null); then
        printf 'could not validate the staged config against the schema (%s) — refusing to commit' "$REFERENCE_CONFIG"
        return 1
    fi
    if [ -n "$unknown" ]; then
        printf 'this change adds config keys not in the schema (%s) — refusing to commit. %s' "$unknown" "$(_control_host_remedy)"
        return 1
    fi
    if control_never_path_changed "$staged"; then
        control_physical_presence_error
        return 1
    fi
    # Every unlisted schema-backed env change joins the typed confirmation tier (#1959).
    local committable_re approval_re bad hit
    committable_re=$(control_committable_re)
    # The only source of this row is workers.list[].api_token. Admit it only after the shared
    # worker gate has proved the change is a strict, SSRF-checked append.
    [ -z "$worker_new" ] || committable_re="$committable_re|WORKER_API_TOKENS"
    bad=$(printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -cvxE "$committable_re" || true)
    if [ "${bad:-0}" -gt 0 ]; then
        approval_required=1
        needs_confirm=1
    fi
    if control_changed_config_paths "$staged" | grep -qxF "$CONTROL_DASHBOARD_APPROVAL_PATHS"; then approval_required=1; fi
    if control_changed_config_paths "$staged" | grep -qxF -e "$CONTROL_DASHBOARD_APPROVAL_PATHS" -e "$CONTROL_DASHBOARD_CONFIRM_PATHS"; then needs_confirm=1; fi
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
    # Disruptive changes require typed APPLY; record confirmed commits via the marker below.
    # An adopted rig (#2641) is confirmed the same way: the dashboard will send it a write token.
    printf '%s\n' "$porcelain" | grep -qE $'^(CONFIRM|DEST)\t' && needs_confirm=1
    [ -z "$worker_new" ] || needs_confirm=1
    if [ "$needs_confirm" -eq 1 ]; then
        if [ "$confirm" != "APPLY" ]; then
            hit=$(printf '%s\n' "$porcelain" | grep -m1 -E $'^CONFIRM\t' | cut -f3-)
            [ -n "$hit" ] || [ -z "$worker_new" ] || hit="adopting a rig: $(printf '%s' "$worker_new" | paste -sd, -)"
            printf 'this change is disruptive (%s) — type APPLY in the dashboard to confirm.' "${hit:-disruptive change}"
            return 1
        fi
        touch "${staged}.confirmed" 2>/dev/null || true
    fi
    # Reachability probe (#1888) — the compensating control the confirm tier rests on for these keys
    # (42-): the typed token is friction, but a chain cannot be parked on a node that is not there.
    # Host-side, on the STAGED config, through the same preflight the wizard uses; nothing is
    # trusted from the container. Fires only when a node endpoint or login really changed (so an
    # unrelated commit is never blocked by a node that is down) and only after the typed
    # confirmation (so an unconfirmed attempt never pays the dial timeouts).
    local probe_err preflight_re
    preflight_re=$(printf '%s' "$CONTROL_NODE_PREFLIGHT_KEYS" | tr -s ' \n' '|')
    if printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -qxE "$preflight_re"; then
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
    # Audit changed path names, never values; this also covers config-only fields (#349/#504).
    {
        control_changed_config_paths "$staged"
        [ -z "$worker_new" ] || printf '%s\n' 'workers.list'
    } | sort -u | tr '\n' ' ' | sed 's/ $//'
    return 0
}

control_preview() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local staged="$cdir/staged/$id.json" errf="$cdir/staged/.$id.err" out result
    local basef="$cdir/staged/.$id.base" base_sum=""
    base_sum=$(control_live_config_sum) # the revision this preview diffs against (#3352)
    if ! out=$(config_document_error "$CONFIG_FILE"); then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$out" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    if [ "$(jq -r '.config | type' "$file")" != "object" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"config must be a JSON object",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    # Require a replacement credential for a masked worker endpoint repoint.
    if ! jq -e --slurpfile live "$CONFIG_FILE" '
        def endpoint($api_port): [(.host // null), (.port // $api_port), (.control_port // 8082)];
        (reduce (($live[0].workers.list // []) | reverse | .[]) as $w ({};
            if ($w | type) == "object" and ($w.name | type) == "string"
            then .[$w.name] = $w else . end)) as $live_workers
        | [(.config.workers.api_port // 8080), ($live[0].workers.api_port // 8080)] as [$candidate_api_port, $live_api_port]
        | all(.config.workers.list[]?;
            if ((.token | type) == "object" and .token.__secret__ == true)
                or ((.api_token | type) == "object" and .api_token.__secret__ == true)
            then (.name | type) == "string"
              and ($live_workers[.name] | type) == "object"
              and endpoint($candidate_api_port) == ($live_workers[.name] | endpoint($live_api_port))
            else true end)' "$file" >/dev/null 2>&1; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"a masked worker token can only stay with its own unchanged descriptor — adopt a new rig with its real token; change an existing rig address on the host (workers.list)",ts:(now|floor)}')"
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
    # Restore masked secrets from live config host-side (#440); unset secrets become "".
    # Per-worker token sentinels (#172) get the same swap, but out of the fixed-path walk: they
    # live in the variable-length descriptor array at workers.list[] (#506) — so restore each from
    # the LIVE token matched by worker name (first-declared wins on duplicate names, matching the
    # container's probe). A sentinel for a rig with no live token collapses to "" too. The endpoint
    # guard above rejects a sentinel without a same-name live descriptor or with a changed
    # host/port/control_port, before any bearer can be restored. Webhook sentinels are positional;
    # control_masked_binding_error refuses a list that no longer lines up with the live one (#2373). dashboard.workers[] is restored too, and
    # MUST be: 30's masker still masks that shape after 2.0.0 removed the alias (#1832, see the note
    # there), and mask and restore are one mechanism. Keeping the mask without the restore would let
    # a sentinel be committed as a literal token.
    # The LIVE lookup below therefore reads BOTH shapes, and that is the whole point: worker_list is
    # workers.list[] alone since #1832, so resolving legacy sentinels against it would find nothing
    # and blank every per-rig token to "" — a restore branch that cannot restore. workers.list[]
    # wins a name present in both (it is the canonical key, and both-populated-and-different is
    # already refused at apply); within one shape, first-declared still wins via the reverse.
    (umask 077 && jq --argjson paths "$CONTROL_SECRET_PATHS" --slurpfile live "$CONFIG_FILE" "$WORKER_LIST_JQ"'
        (reduce (($live[0] | worker_list) + (($live[0].dashboard // {}) | .workers // []) | reverse | .[]) as $w ({};
            if ($w | type) == "object" and ($w.name | type) == "string"
            then .[$w.name] = {token: ($w.token // ""), api_token: ($w.api_token // "")} else . end)) as $livetok
        | if ((.config | has("ssh") | not) and ($live[0] | has("ssh"))) then .config.ssh = $live[0].ssh else . end
        | reduce $paths[] as $p (.config;
            (try getpath($p) catch null) as $v
            | if ($v | type) == "object" and $v.__secret__ == true
              then setpath($p; (($live[0] | try getpath($p) catch null) // ""))
              else . end)
        | if ($live[0] | has("config_version")) then .config_version = $live[0].config_version else del(.config_version) end
        | if (.workers | type) == "object" and (.workers.list | type) == "array"
          then .workers.list |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name].token // "") else "" end)
              else . end
              | if (.api_token | type) == "object" and .api_token.__secret__ == true
                then .api_token = (if (.name | type) == "string" then ($livetok[.name].api_token // "") else "" end)
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
              then .token = (if (.name | type) == "string" then ($livetok[.name].token // "") else "" end)
              else . end
              | if (.api_token | type) == "object" and .api_token.__secret__ == true
                then .api_token = (if (.name | type) == "string" then ($livetok[.name].api_token // "") else "" end)
                else . end)
          else . end' "$file" >"$staged")
    chmod 600 "$staged" 2>/dev/null || true
    (umask 077 && printf '%s\n' "$base_sum" >"$basef")
    local policy_error
    if policy_error=$(control_preview_policy_error "$staged"); then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$policy_error" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    local carried_ssh=0
    control_carried_ssh "$staged" && carried_ssh=1
    if out=$(PITHEAD_CONFIG_FILE="$staged" PITHEAD_CONFIG_CARRIED_SSH="$carried_ssh" "$0" apply --dry-run --porcelain 2>"$errf"); then
        # Unlisted reference values confirm (#1959). Worker descriptors use the gate's classifier: an
        # adopt previews as a CONFIRM row below; a repoint, reorder, removal or SSRF-floor host
        # refuses here, before the operator is asked to type anything.
        local approval_required=false committable_re approval_re bad worker_new worker_err="" config_paths
        committable_re=$(control_committable_re)
        # Classify worker changes before treating unlisted rows as confirmable.
        worker_new=$(control_worker_append "$staged") || { worker_err="${worker_new:-could not classify the worker descriptors — refusing}" && worker_new=""; }
        [ -z "$worker_new" ] || committable_re="$committable_re|WORKER_API_TOKENS"
        bad=$(printf '%s' "$out" | awk -F'\t' 'NF' | cut -f2 | grep -cvxE "$committable_re" || true)
        if control_never_path_changed "$staged"; then
            control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(control_physical_presence_error)" '{status:"rejected",error:$e,ts:(now|floor)}')"
            rm -f "$errf"
            control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
            return 0
        fi
        if [ -n "$worker_err" ]; then
            control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$worker_err" '{status:"rejected",error:$e,ts:(now|floor)}')"
            # The staged intent STAYS (unlike a validation failure) so a commit attempt still
            # reaches the gate, which names the boundary it hit (stick, SSRF floor, perimeter key).
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
              or ($p[0:2] == ["workers","list"] and ($p[-1] == "token" or $p[-1] == "api_token"))
              or ($p[0:2] == ["dashboard","workers"] and ($p[-1] == "token" or $p[-1] == "api_token"))
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
        # An adopted rig (#2641): a CONFIRM row, so the preview is destructive and the commit needs
        # the typed APPLY. The warning names what is trusted; never the token.
        if [ -n "$worker_new" ]; then
            result=$(printf '%s' "$result" | jq --arg rigs "$(printf '%s' "$worker_new" | paste -sd, - | sed 's/,/, /g')" '.changes += [{flag:"CONFIRM",key:"workers.list",msg:"Adopting a rig: \($rigs). The dashboard will send this rig'"'"'s control token to that address and can change its pools and its thermal limits from then on, so check the address is the rig itself. Changing or removing an adopted rig is not possible from the dashboard."}] | .destructive = true')
        fi
        # local_miner.enabled (2026-09-13 perimeter audit round 2): also config.json-only, no
        # porcelain row. Ordinary like dashboard.energy — a documented dashboard toggle
        # (docs/workers.md), not a security control — but named explicitly rather than left
        # unaccounted for, which is the exact gap that let it bypass classification entirely.
        if ! jq -e --slurpfile live "$CONFIG_FILE" '(.local_miner.enabled // false) == ($live[0].local_miner.enabled // false)' "$staged" >/dev/null 2>&1; then
            result=$(printf '%s' "$result" | jq '.changes += [{flag:"INFO",key:"local_miner.enabled",msg:"The co-located local miner toggle changed."}]')
        fi
        control_write_result "$cdir/results" "$id" "$result"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "previewed" "$(porcelain_keys "$out${worker_new:+$'\nINFO\tworkers.list'}")"
    else
        # Validation failed — reject with pithead's own error tail; nothing stays staged.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$errf")" '{status:"rejected",log:$e,ts:(now|floor)}')"
        rm -f "$staged" "$basef"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
    fi
    rm -f "$errf"
}

# Commit: apply the HOST-SIDE staged copy from the matching preview. A tampered second request
# can't swap the config — commit carries only the id; the config it applies is the one previewed.
control_commit() { # <id> <actor> <control-dir> [confirm-token] [approval-json]
    local id="$1" actor="$2" cdir="$3" confirm="${4:-}" approval="${5:-null}"
    local staged="$cdir/staged/$id.json" logf="$cdir/staged/.$id.log" rc=0 carried_ssh=0
    local basef="$cdir/staged/.$id.base"
    control_commit_unusable "$id" "$actor" "$cdir" && return 0
    # On refusal the gate's stdout is the reason; on approval it is the changed key names, which
    # the audit entries below record — WHAT changed, by name only (#349).
    local gate_out audit_keys=""
    if ! gate_out=$(control_approval_gate "$staged" "$confirm" "$id" "$actor" "$approval" "$cdir"); then
        [ -n "$gate_out" ] || gate_out="approval denied"
        rm -f "$staged" "$basef" "${staged}.confirmed"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$gate_out" '{status:"rejected",error:$e,ts:(now|floor)}')"
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
    control_carried_ssh "$staged" && carried_ssh=1
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak-control"
    cp "$staged" "$CONFIG_FILE"
    PITHEAD_CONFIG_CARRIED_SSH="$carried_ssh" "$0" apply -y >"$logf" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        control_reown_operator_files # the root apply wrote .env/Caddyfile as root — give them back (#33)
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "applied" "$audit_keys" "$approver"
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"applied",ts:(now|floor)}')"
    else
        # apply's own .apply-incomplete marker handles the container-recreate retry; the config
        # backup lets the operator revert by hand if the new config itself is the problem.
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "failed" "$audit_keys" "$approver"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" --arg b "${CONFIG_FILE}.bak-control" '{status:"failed",error:$e,backup:$b,ts:(now|floor)}')"
    fi
    rm -f "$staged" "$basef" "$logf" "${staged}.confirmed"
}
