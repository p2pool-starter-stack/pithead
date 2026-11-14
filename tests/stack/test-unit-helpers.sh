# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Unit-helper domain (#1105 Phase 1, appliance lane): the cluster of small helper tests that sat
# at the head of run.sh. Five of them drive a pithead function through run_sourced and assert its
# return code or its stdout — docker_boot_enabled (a systemctl stub on PATH decides which unit
# reports enabled, and docker.service or docker.socket each count on their own), config_bool (a
# config value written explicitly false must stay false rather than be coerced by jq's // default,
# the #294 regression that silently re-enabled the firewall opt-out), migrate_legacy_workers (a
# v1.x xmrig_proxy block at its reference defaults never conflicts with xvb.*, #2690), env_get_file and
# env_changed_keys (a value containing an "=" survives intact, and only the keys that differ are
# reported), and export_build_provenance (the VERSION file is read and whitespace-trimmed, and an
# absent VERSION yields an empty version rather than an error). The sixth block is a drift guard
# rather than a unit test: it pins the XvB tier thresholds in the dashboard's config.py against the
# human forms written in docs/architecture.md, so the user-facing table cannot fall out of sync
# with TIER_DEFAULTS unnoticed.
# Sourced by tests/stack/run.sh.
#
# NAMED FOR WHAT IT HOLDS. The cut map filed this range under "config-helpers"; of the five blocks
# only config_bool is a config helper, the XvB block is not a helper test at all, and
# tests/stack/test-config.sh already exists — a near-identical neighbour name would send a reader
# to the wrong file.
#
# THIS CUT REORDERS, and saying so is the point. The range is NOT contiguous: domain source
# stanzas are interleaved between these blocks, and every one of them is EXCLUDED from the cut
# rather than nested. (Nesting a stanza would leave the outer domain_ran guard reading the value
# the nested stanza set, so the extracted content would carry zero zero-assertion coverage — not
# narrowed coverage, zero.) Excluding them leaves three pieces, so one vacated position takes the
# source stanza and the others close up. The anchor is the last piece's position, chosen because it
# leaves the most sections standing: the XvB, env-helper and provenance blocks execute exactly
# where they always did, and only the docker_boot_enabled and config_bool blocks move later. They
# do not cross the same set. docker_boot_enabled now runs after test-control-upgrade.sh,
# test-release-signing.sh, test-dashboard.sh, test-dashboard-onion.sh and test-release.sh;
# config_bool after the last three of those. Every other domain file keeps its position.
#
# WHY THAT REORDER IS SAFE, argued in both directions.
#   Outward: the names these blocks assign — $BOOT, $tier_cfg, $tier_doc, $changed, $PROV, $NOVER,
#   $ver and the drift loop's own $tier, $t_name, $t_rest, $t_val and $t_human — are read nowhere
#   else, in run.sh or anywhere else under tests/stack. Swept per name over every tests/stack/*.sh
#   with comments stripped first, because a comment naming a variable is not a read and this lane
#   has been bitten by that three times; the surviving hits were then read individually rather than
#   counted. The
#   one shared name is $CB: this file's config_bool block and tests/stack/test-monero-tari.sh both
#   work in $SANDBOX/cb. That file assigns $CB, mkdir -p's it and writes its own config.json, so it
#   inherits nothing from here — and its stanza is sourced after this file's stanza both before and
#   after the cut.
#   Inward: these blocks read only $SANDBOX, $ROOT and $STACK, each assigned at COLUMN 1 at top
#   level in lib.sh, outside every function body — so none of them is the ordering dependency the
#   $WALLET case turned out to be. (Re-derive by grepping lib.sh for the assignment and reading the
#   indent, not by line number: a citation into another file is the perishable part of any claim
#   here.) The domain files the two moved blocks now run after reassign none of those three and
#   create no systemctl stub that could shadow this file's own; every PATH replacement and every cd
#   in them is confined to a subshell or to a function whose whole body is a subshell. Every path
#   this file writes or reads is anchored on $SANDBOX, $ROOT or $STACK, or is reached by an
#   explicit cd inside a command substitution, so a leaked working directory could not reach them
#   either.
#   The provider functions called are run_sourced, assert_rc, assert_eq, ok and bad.

: "${ROOT:?}" "${SANDBOX:?}" "${STACK:?}"

echo "== unit: docker_boot_enabled (#137) =="
# A systemctl stub on PATH; FAKE_BOOT picks which unit reports "enabled". Docker counts as
# boot-enabled if EITHER docker.service or docker.socket is enabled.
BOOT="$SANDBOX/boot"
mkdir -p "$BOOT/bin"
cat >"$BOOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "is-enabled docker.service") [ "${FAKE_BOOT:-}" = "service" ] && exit 0 || exit 1 ;;
  "is-enabled docker.socket")  [ "${FAKE_BOOT:-}" = "socket"  ] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BOOT/bin/systemctl"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=service run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.service enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=socket run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.socket enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=none run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "neither enabled -> 1" "$?" "1"

echo "== unit: config_bool honours an explicit false (jq // false-coercion guard, #294) =="
# Regression for #294: `.x // true` returns true even when x is explicitly false (jq treats false as
# empty), which silently broke the #270 firewall opt-out (config false → .env stayed true) and
# xvb.tor=false. config_bool null-checks instead. CONFIG_FILE is the relative "config.json", so a
# fixture in the cwd is what the sourced helper reads.
CB="$SANDBOX/cb"
mkdir -p "$CB"
printf '{"network":{"tor_egress_firewall":false},"xvb":{"tor":false}}' >"$CB/config.json"
assert_eq "explicit false honoured (firewall)" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "false"
assert_eq "explicit false honoured (xvb.tor)" "$(run_sourced "$CB" config_bool '.xvb.tor' true)" "false"
printf '{"network":{"tor_egress_firewall":true}}' >"$CB/config.json"
assert_eq "explicit true honoured" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
printf '{}' >"$CB/config.json"
assert_eq "absent -> default true" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
assert_eq "ungoverned absent -> supplied default false" "$(run_sourced "$CB" config_bool '.dashboard.control.enabled' false)" "false"

echo "== unit: migrate_legacy_workers drops v1.x xmrig_proxy defaults beside a customised xvb (#2690) =="
MX="$SANDBOX/mx"
mkdir -p "$MX"
printf '{"xvb":{"enabled":false,"url":"eu.xmrvsbeast.com:4247","donor_id":"mine"},"xmrig_proxy":{"enabled":true,"url":"na.xmrvsbeast.com:4247","donor_id":"auto"}}' >"$MX/config.json"
run_sourced "$MX" migrate_legacy_workers >/dev/null 2>&1
assert_rc "an editor-saved v1.x xmrig_proxy at its defaults is no conflict" "$?" "0"
assert_eq "the default block is dropped, the customised xvb kept" "$(jq -c '[has("xmrig_proxy"), .xvb]' "$MX/config.json")" '[false,{"enabled":false,"url":"eu.xmrvsbeast.com:4247","donor_id":"mine"}]'
printf '{"xvb":{"url":"eu.xmrvsbeast.com:4247"},"xmrig_proxy":{"url":"us.xmrvsbeast.com:4247"}}' >"$MX/config.json"
mx_out="$(run_sourced "$MX" migrate_legacy_workers 2>&1)"
assert_rc "a non-default xmrig_proxy.url that differs from xvb.url is refused" "$?" "1"
assert_contains "the refusal names the xvb pair" "$mx_out" "(xvb.url and xmrig_proxy.url)"

echo "== unit: migrate_telegram_alert_level maps 2.0.0 telegram.enabled and telegram.events to telegram.level (#3578) =="
TL="$SANDBOX/tl"
mkdir -p "$TL"
tl_run() {
    printf '%s' "$1" >"$TL/config.json"
    TL_OUT="$(run_sourced "$TL" migrate_telegram_alert_level 2>&1)"
}
tl_level() { jq -c '[.telegram.level, (.telegram | has("enabled")), (.telegram | has("events"))]' "$TL/config.json"; }
tl_off() {
    jq -nc --argjson drop "$1" '$drop | map({(.): false}) | add'
}
tl_all_only='["worker_joined","worker_left","stack_online","daily_summary","block_found","new_release"]'
tl_important_only='["worker_offline","worker_recovered","sync_finished","db_reset","xvb_no_share","xvb_registration","hashrate_low","high_reject_rate","hugepages","low_ram","payout_found","payout_confirmed","raffle_win"]'
tl_critical='["node_down","node_recovered","container_unhealthy","db_unhealthy","disk_space","hashrate_loss"]'
tl_cfg() { jq -nc --argjson ev "$1" '{telegram:{enabled:true,bot_token:"t",chat_id:"1",events:$ev}}'; }
tl_run '{"telegram":{"enabled":true,"bot_token":"t","chat_id":"1"}}'
assert_eq "every toggle on maps to all" "$(tl_level)" '["all",false,false]'
assert_eq "a config that already delivered everything warns of nothing" "$TL_OUT" ""
tl_run "$(tl_cfg "$(tl_off "$tl_all_only")")"
assert_eq "everything but the all-only alerts maps to important" "$(tl_level)" '["important",false,false]'
assert_eq "an exact level match warns of nothing" "$TL_OUT" ""
tl_run "$(tl_cfg "$(tl_off '["node_down"]')")"
assert_eq "one switch off still maps to all" "$(tl_level)" '["all",false,false]'
assert_contains "the alert that starts is named" "$TL_OUT" "Alerts that start: node_down"
tl_run "$(tl_cfg "$(tl_off "$(jq -nc --argjson a "$tl_all_only" --argjson b "$tl_important_only" '$a + $b')")")"
assert_eq "only the six critical alerts on maps to critical" "$(tl_level)" '["critical",false,false]'
tl_run "$(tl_cfg "$(tl_off "$(jq -nc --argjson a "$tl_all_only" --argjson b "$tl_important_only" --argjson c "$tl_critical" '$a + $b + $c')")")"
assert_eq "an empty set maps to off" "$(tl_level)" '["off",false,false]'
assert_eq "an empty set warns of nothing" "$TL_OUT" ""
tl_run "$(tl_cfg "$(tl_off "$(jq -nc --argjson a '["worker_left","stack_online","daily_summary","block_found","new_release"]' --argjson b "$tl_important_only" '$a + $b')")")"
assert_eq "critical plus one extra alert maps to critical" "$(tl_level)" '["critical",false,false]'
assert_contains "the extra alert that stops is named" "$TL_OUT" "Alerts that stop: worker_joined"
tl_run "$(tl_cfg "$(tl_off '["worker_left","stack_online","daily_summary"]')")"
assert_eq "a tie between two levels goes to the more verbose" "$(tl_level)" '["all",false,false]'
tl_run '{"telegram":{"bot_token":"t","chat_id":"1","events":{"node_down":false}}}'
assert_eq "credentials without enabled map to off" "$(tl_level)" '["off",false,false]'
assert_contains "the always-on alarms that start are named" "$TL_OUT" "wallet_changed, clearnet_exposed, payout_wallet_down"
tl_run '{"telegram":{"enabled":false,"bot_token":"t","chat_id":"1"}}'
assert_eq "credentials with enabled false map to off" "$(tl_level)" '["off",false,false]'
tl_run '{"telegram":{"enabled":true,"bot_token":"t","chat_id":"1","events":{"wallet_changed":false}}}'
assert_contains "a switched-off tamper alarm warns that the alarms are now always on" "$TL_OUT" "tamper alarms are now always on"
tl_run '{"telegram":{"enabled":true,"bot_token":"   ","chat_id":"1","events":{"node_down":false}}}'
assert_eq "a blank token counts as no credentials" "$(tl_level)|$TL_OUT" '["off",false,false]|'
tl_run '{"telegram":{"enabled":"true","bot_token":"t","chat_id":"1"}}'
assert_eq "a string true still counts as enabled" "$(tl_level)" '["all",false,false]'
tl_run '{"telegram":{"bot_token":"t","chat_id":"1","events":{"clearnet_exposed":false}}}'
assert_contains "a switched-off tamper alarm warns even when Telegram was disabled" "$TL_OUT" "tamper alarms are now always on"
tl_run '{"telegram":{"enabled":false,"bot_token":"t","chat_id":"1","commands":{"enabled":true}}}'
assert_eq "commands stay off when Telegram was disabled" "$(jq -c '.telegram.commands.enabled' "$TL/config.json")" "false"
assert_contains "the warning says the command bot was switched off" "$TL_OUT" "telegram.commands.enabled was set to false"
tl_run '{"telegram":{"enabled":true,"bot_token":"","chat_id":""}}'
assert_eq "no credentials map to off without a warning" "$(tl_level)|$TL_OUT" '["off",false,false]|'
tl_run '{"telegram":{"enabled":true,"bot_token":"t","chat_id":"1","events":{"worker_joined":false}}}'
tl_before="$(cat "$TL/config.json")"
TL_OUT="$(run_sourced "$TL" migrate_telegram_alert_level 2>&1)"
assert_eq "a second run changes nothing and says nothing" "$(cat "$TL/config.json")|$TL_OUT" "$tl_before|"
printf '%s' '{"telegram":{"enabled":true,"bot_token":"t","chat_id":"1"}}' >"$TL/config.json"
tl_before="$(cat "$TL/config.json")"
tl_out="$(run_sourced "$TL" eval 'PITHEAD_DRY_RUN=1; migrate_telegram_alert_level' 2>&1)"
assert_eq "a dry run writes nothing" "$(cat "$TL/config.json")|$tl_out" "$tl_before|"

echo "== unit: the Telegram level table agrees across the dashboard, the CLI and docs/telegram.md (#3578) =="
tl_table="$(PYTHONPATH="$ROOT/dashboard" python3 -c '
from mining_dashboard.service.notify.alert_levels import ALL_EVENTS, ALWAYS_ON_EVENTS, CRITICAL_EVENTS, IMPORTANT_EVENTS
for event in sorted(ALL_EVENTS | ALWAYS_ON_EVENTS):
    level = "always" if event in ALWAYS_ON_EVENTS else "critical" if event in CRITICAL_EVENTS else "important" if event in IMPORTANT_EVENTS else "all"
    print(event, level)
')"
tl_docs="$(awk -F'|' '$2 ~ /^ `[a-z_]+` $/ && $3 ~ /^ (always|critical|important|all) $/ { gsub(/[ `]/, "", $2); gsub(/ /, "", $3); print $2, $3 }' "$ROOT/docs/telegram.md" | sort)"
assert_eq "the dashboard level table has 28 alerts" "$(wc -l <<<"$tl_table" | tr -d ' ')" "28"
assert_eq "docs/telegram.md lists every alert with the dashboard's level" "$tl_docs" "$(sort <<<"$tl_table")"
tl_cli=""
for tl_level in critical important all; do
    for tl_event in $(run_sourced "$SANDBOX" telegram_level_events "$tl_level"); do
        tl_cli="$tl_cli$tl_event $tl_level"$'\n'
    done
done
tl_cli_first="$(awk 'NF && !seen[$1]++' <<<"$tl_cli" | sort)"
assert_eq "the CLI level table matches the dashboard's optional alerts" "$tl_cli_first" "$(grep -v ' always$' <<<"$tl_table" | sort)"

echo "== unit: telegram level descriptions (#3578) =="
assert_contains "raising the level names the alerts that start" "$(run_sourced "$SANDBOX" describe_change TELEGRAM_LEVEL off critical)" "Starts: node_down"
assert_contains "lowering the level names the alerts that stop" "$(run_sourced "$SANDBOX" describe_change TELEGRAM_LEVEL all critical)" "Stops: worker_offline"
assert_contains "a level change names the always-on alarms" "$(run_sourced "$SANDBOX" describe_change TELEGRAM_LEVEL all off)" "stay on at every level"
assert_not_contains "a level change is not a tamper-alarm switch-off" "$(run_sourced "$SANDBOX" describe_change TELEGRAM_LEVEL critical off)" "DEST"

# The XvB tier thresholds are hard-coded in config.py (TIER_DEFAULTS) and stated explicitly in
# docs/architecture.md. Drift guard: each config value must match the doc's human form, so the
# user-facing table can't silently fall out of sync if TIER_DEFAULTS ever changes.
tier_cfg="$ROOT/dashboard/mining_dashboard/config/config.py"
tier_doc="$ROOT/docs/architecture.md"
for tier in "donor:1_000:1 kH/s" "vip:10_000:10 kH/s" "whale:100_000:100 kH/s" "mega:1_000_000:1 MH/s"; do
    t_name="${tier%%:*}"
    t_rest="${tier#*:}"
    t_val="${t_rest%%:*}"
    t_human="${t_rest#*:}"
    if grep -qE ": ${t_val}[ ,]" "$tier_cfg" && grep -qF "$t_human" "$tier_doc"; then
        ok "XvB $t_name tier: config.py $t_val matches docs '$t_human'"
    else
        bad "XvB $t_name tier docs match TIER_DEFAULTS" "config $t_val / doc '$t_human' out of sync"
    fi
done

echo "== unit: env helpers =="
printf 'A=1\nB=two\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/old.env"
printf 'A=1\nB=three\nC=4\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/new.env"
assert_eq "env_get_file reads value" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" B)" "two"
assert_eq "env_get_file value with =" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" PROXY_AUTH_TOKEN)" "keep=me"
literal=$' single\'quote "double" \\path\\ $HOME\t# text\nnext '
rendered="$(run_sourced "$SANDBOX" dotenv_render_value "$literal")"
printf 'LITERAL=%s\nORDINARY=plain-value\n' "$rendered" >"$SANDBOX/literal.env"
assert_eq "dotenv literal round-trip" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/literal.env" LITERAL)" "$literal"
assert_eq "dotenv ordinary value stays unquoted" \
    "$(run_sourced "$SANDBOX" dotenv_render_value '--mini --flag')" "--mini --flag"
changed="$(run_sourced "$SANDBOX" env_changed_keys "$SANDBOX/old.env" "$SANDBOX/new.env" | sort | tr '\n' ' ')"
assert_eq "env_changed_keys finds B and C" "$changed" "B C "

echo "== unit: export_build_provenance (Issue #58) =="
# Exports the stack version (from the top-level VERSION file, whitespace-trimmed) plus git
# branch/commit for the dashboard build args — deliberately NOT written into .env, since the
# volatile commit would otherwise churn `apply`. The sandbox isn't a git repo, so branch/commit
# come back empty here; the release/dev split is unit-tested in dashboard/tests/test_version.py.
PROV="$SANDBOX/prov"
mkdir -p "$PROV"
printf '  9.9.9 \n' >"$PROV/VERSION"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$PROV" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance reads VERSION (trimmed)" "$ver" "9.9.9"
NOVER="$SANDBOX/nover"
mkdir -p "$NOVER"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$NOVER" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance empty when no VERSION" "$ver" ""

echo "== unit: support-bundle archive is never exposed while it is written (#3757) =="

bundle_case() {
    local tar_mode="$1" preexisting="${2:-}" work
    mk_tmpdir work
    chmod 755 "$work"
    if [ -n "$preexisting" ]; then
        printf old >"$work/$preexisting"
        chmod 644 "$work/$preexisting"
    fi
    (
        cd "$work" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        umask 022
        log() { :; }
        doctor_json() { echo '{}'; }
        docker() { return 1; }
        date() { printf 'FIXED'; }
        tar() {
            local out="" a
            for a in "$@"; do case "$a" in *.tar.gz) out="$a" ;; esac done
            command tar "$@" || return
            printf 'DIR:%s\n' "$(ls -ld "${out%/*}" | cut -c1-10)"
            printf 'TMP:%s\n' "${out%/*}"
            printf 'FILE:%s\n' "$(ls -l "$out" | cut -c1-10)"
            printf 'VISIBLE:%s\n' "$(find "$work" -maxdepth 1 -name 'support-bundle-*.tar.gz' | wc -l | tr -d ' ')"
            case "$tar_mode" in
            fail) return 1 ;;
            term) kill -TERM "$BASHPID" ;;
            esac
        }
        render_masked_config() { return 1; }
        stack_support_bundle
        echo "RC:$?"
    ) 2>&1
    echo "FILES:$(find "$work" -maxdepth 1 -name 'support-bundle-*.tar.gz' | wc -l | tr -d ' ')"
    if [ -n "$preexisting" ]; then
        echo "FINAL:$(ls -l "$work/$preexisting" | cut -c1-10)"
    fi
    rm -rf "$work"
}

bundle_tmp_gone() { [ ! -e "$(printf '%s\n' "$1" | sed -n 's/^TMP://p')" ]; }

ok_out="$(bundle_case ok)"
assert_contains "the archive is built in a private directory" "$ok_out" "DIR:drwx------"
assert_contains "no archive is visible in the output directory while tar writes" "$ok_out" "VISIBLE:0"
assert_contains "the verb succeeds" "$ok_out" "RC:0"
assert_contains "the finished archive is published" "$ok_out" "FILES:1"
bundle_tmp_gone "$ok_out" && ok "the scratch directory is removed after success" || bad "the scratch directory is removed after success" "$ok_out"

pre_out="$(bundle_case ok support-bundle-FIXED.tar.gz)"
assert_contains "a permissive archive already at the output path is replaced owner-only" "$pre_out" "FINAL:-rw-------"

fail_out="$(bundle_case fail)"
assert_contains "a failed tar fails the verb" "$fail_out" "RC:1"
assert_contains "a failed tar leaves no archive" "$fail_out" "FILES:0"
bundle_tmp_gone "$fail_out" && ok "a failed tar removes the scratch directory" || bad "a failed tar removes the scratch directory" "$fail_out"

term_out="$(bundle_case term)"
assert_contains "an interrupted run leaves no archive" "$term_out" "FILES:0"
assert_not_contains "an interrupted run never reaches the end of the verb" "$term_out" "RC:"
bundle_tmp_gone "$term_out" && ok "an interrupted run removes the scratch directory" || bad "an interrupted run removes the scratch directory" "$term_out"
