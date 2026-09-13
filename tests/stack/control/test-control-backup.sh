# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel one-time-kit domain (#1105 Phase 1, appliance lane): both verbs in
# lib/pithead/45-control-backup.sh that hand a secret back through results/ and then take it away
# again. control_backup (#908) generates its OWN passphrase rather than accepting one from the
# container and runs the real backup as a child "$self backup -y", so stack_backup's own error()
# exit cannot take the drain loop's other pending requests with it; the one-time kit it hands back
# is visible for its TTL and redacted afterwards, including when a runner dies mid-TTL; and the
# failure and throttle paths are covered alongside. control_onion_client_key (#1882) is the second
# kit shape: the Tor client-auth credential without which a client-auth'd dashboard onion cannot be
# opened at all, which until then was printed only by a host CLI verb an appliance has no shell to
# run. Its preconditions come from onion_client_credential (32-onion-provisioning.sh), tested here
# rather than beside that slice because its only two callers are that CLI verb and this one, and
# because tests/stack/dashboard/test-dashboard-onion.sh sits at its recorded file-budget ceiling.
# Sourced by tests/stack/run.sh.
#
# This domain IS standalone-sourceable once tests/stack/lib.sh has been sourced, and it needs
# nothing from any sibling domain file. It is not a consumer of the shared control sandbox: it
# never calls build_control_sandbox(), and it never reads $C, $CTRL_LOG or the request-spool
# globals. It builds its own control directory under $SANDBOX instead. So the add-only-ssrf
# disclosure precedent that governs the pure-consumer control domains does not apply here, and
# neither does the position lock that comes with it: this domain reads no state a sibling leaves
# behind, writes nothing outside its own directory under $SANDBOX, and unsets the environment it
# exports before it ends. Both directions were checked, and both are re-derivable with grep here.
#
# Re-derivations, audited over this WHOLE file, this header included. The audit script is
# lane-local and is NOT in this repo, so nothing below rests on it: each claim is written to be
# re-derived here with git and grep alone, and should be treated as a claim to check.
# - $SANDBOX and $STACK are the ONLY names this file reads without assigning. Both are lib.sh
#   top-level constants, assigned at column 1 rather than inside a function — the distinction that
#   matters, because a name a provider assigns only inside a function reaches a domain file as an
#   ordering dependency and not as a constant. The guard below states both requirements explicitly.
#   ($STACK arrived with the #1882 rows, which source the CLI directly so they can shadow one of
#   its functions; before them $SANDBOX really was the only one.)
# - $BKC is assigned here, in the moved text, not inherited.
# - The lib.sh helpers this domain calls (assert_contains, assert_eq, bad, ok, run_sourced) are
#   likewise defined at lib.sh's top level.

: "${SANDBOX:?}"
: "${STACK:?}"

# ---------------------------------------------------------------------------
echo "== control channel: backup verb (#908) =="
# control_backup generates its OWN passphrase (never accepted from the container), runs the
# real backup as a CHILD "$self backup -y" (stack_backup's own error() exits its process, which
# must not take the drain loop's other pending requests with it), and hands back a one-time kit
# through results/. A stub self reproduces stack_backup's own "Backup written to: <path>" log
# line so this stays a fast, docker-free test of the GLUE — the archive mechanics themselves are
# already covered by the backup/restore round-trip tests above (#140/#374).
BKC="$SANDBOX/ctrl908"
mkdir -p "$BKC/staged" "$BKC/results" "$BKC/audit"
cat >"$BKC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${SELF_LOG:-/dev/null}"
printf '%s\n' "${PITHEAD_BACKUP_PASSPHRASE:-<empty>}" >>"${PASS_LOG:-/dev/null}"
if [ "${BACKUP_FAIL:-0}" = "1" ]; then
    echo "boom: disk full" >&2
    exit 1
fi
mkdir -p "$(dirname "$FAKE_ARCHIVE")"
printf 'FAKE-ENCRYPTED-BYTES' >"$FAKE_ARCHIVE"
echo "[pithead] Backup written to: $FAKE_ARCHIVE"
exit 0
EOF
chmod +x "$BKC/self"
export PITHEAD_SELF="$BKC/self"
export SELF_LOG="$BKC/self.log"
export PASS_LOG="$BKC/pass.log"
export CONTROL_BACKUP_KIT_TTL_S=0 # redact immediately — this block only checks the applied shape

bid1="a0a0a0a0-0000-4000-8000-000000000001"
export FAKE_ARCHIVE="$BKC/fake-backups/pithead-backup-20260813-000000.tar.gz.enc"
: >"$SELF_LOG"
: >"$PASS_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid1" >"$BKC/req1.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req1.json" "$BKC" >/dev/null 2>&1
assert_eq "backup runs the fixed 'backup -y' verb (never --no-encrypt)" "$(cat "$SELF_LOG")" "backup -y"
assert_eq "backup result is applied" "$(jq -r .status "$BKC/results/$bid1.json")" "applied"
pass1="$(cat "$PASS_LOG")"
{ [ -n "$pass1" ] && [ "$pass1" != "<empty>" ]; } &&
    ok "the child gets a non-empty passphrase (via env, never argv)" ||
    bad "the child gets a non-empty passphrase (via env, never argv)" "got: $pass1"
assert_eq "the passphrase never rides argv (the child's own argv log shows only 'backup -y')" \
    "$(cat "$SELF_LOG")" "backup -y"
assert_eq "the kit names the archive by basename" \
    "$(jq -r .archive "$BKC/results/$bid1.json")" "pithead-backup-20260813-000000.tar.gz.enc"
assert_contains "the kit lists what the archive holds" \
    "$(jq -r '.contents | join(",")' "$BKC/results/$bid1.json")" "config.json"
[ -f "$BKC/results/$bid1.tar.gz.enc" ] &&
    ok "the archive lands under results/ (the container's existing ro mount — no new bind mount)" ||
    bad "the archive lands under results/ (the container's existing ro mount — no new bind mount)" "missing"
assert_eq "the archive's content is preserved by the move into results/" \
    "$(cat "$BKC/results/$bid1.tar.gz.enc")" "FAKE-ENCRYPTED-BYTES"
assert_contains "backup is audited applied" \
    "$(cat "$BKC/audit/control.log")" '"action":"backup","status":"applied"'
# TTL=0 above means the redaction ran synchronously before control_process_request returned.
assert_eq "the passphrase is gone once the TTL elapses (redacted in place, whether read or not)" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/$bid1.json")" "null"
assert_contains "the redaction note explains the passphrase is gone" \
    "$(jq -r .note "$BKC/results/$bid1.json")" "no longer available"
assert_eq "the archive name survives the redaction (ciphertext stays downloadable)" \
    "$(jq -r .archive "$BKC/results/$bid1.json")" "pithead-backup-20260813-000000.tar.gz.enc"

echo "== control channel: backup verb — the kit is visible before its TTL, gone after (#908) =="
# A wider TTL, checked mid-flight: the passphrase is readable for a real window (long enough for
# an ordinary dashboard poll), then null either way — "consumed or not, it's gone".
rm -f "$BKC/staged/.backup-stamp" # bid1 above already claimed the 10-minute throttle
bid2="a0a0a0a0-0000-4000-8000-000000000002"
export FAKE_ARCHIVE="$BKC/fake-backups/pithead-backup-20260813-000001.tar.gz.enc"
export CONTROL_BACKUP_KIT_TTL_S=3
: >"$SELF_LOG"
: >"$PASS_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid2" >"$BKC/req2.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req2.json" "$BKC" >/dev/null 2>&1 &
bg_pid=$!
# The mid-flight read races the background write, so it waits on the condition rather than on a
# fixed budget; why a tick budget is wrong is #1495's lesson and lives on wait_while_alive itself.
# What is specific to this row: when the old `sleep 0.5` lost, jq read a result file that was not
# there yet and the row redded with `got: null`, the exact text a real TTL defect prints. The
# writer cannot exit before it redacts (lib/pithead/45-control-backup.sh), so it outlives the
# window by construction and a give-up means it published nothing at all.
bkc_kit_published() { # #1495: see wait_while_alive in lib.sh
    mid_pass="$(jq -r '.passphrase // "null"' "$BKC/results/$bid2.json" 2>/dev/null)"
    [ -n "$mid_pass" ] && [ "$mid_pass" != "null" ]
}
wait_while_alive "$bg_pid" bkc_kit_published &&
    ok "the passphrase IS present while inside the TTL window" ||
    bad "the passphrase IS present while inside the TTL window" \
        "got: ${mid_pass:-none} — the writer exited without publishing one: a broken write, not a slow box"
assert_eq "the kit's passphrase is exactly what the child received (same secret both ends)" \
    "$mid_pass" "$(cat "$PASS_LOG")"
wait "$bg_pid"
assert_eq "the passphrase is null once the TTL elapses" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/$bid2.json" 2>/dev/null)" "null"
[ -f "$BKC/results/$bid2.tar.gz.enc" ] &&
    ok "the archive file itself is untouched by the redaction" ||
    bad "the archive file itself is untouched by the redaction" "missing"
unset bg_pid mid_pass
unset -f bkc_kit_published

echo "== control channel: backup verb — failure and throttle (#908) =="
rm -f "$BKC/staged/.backup-stamp" # bid2 above already claimed the 10-minute throttle
bid3="a0a0a0a0-0000-4000-8000-000000000003"
export CONTROL_BACKUP_KIT_TTL_S=0
export BACKUP_FAIL=1
: >"$SELF_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid3" >"$BKC/req3.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req3.json" "$BKC" >/dev/null 2>&1
assert_eq "a failed child backup is reported failed, not applied" \
    "$(jq -r .status "$BKC/results/$bid3.json")" "failed"
assert_contains "the failure carries the child's own error tail" \
    "$(jq -r .error "$BKC/results/$bid3.json")" "boom: disk full"
assert_eq "a failed backup's result never carries a passphrase field" \
    "$(jq -r 'has("passphrase")' "$BKC/results/$bid3.json")" "false"
assert_contains "the failed attempt is audited" \
    "$(cat "$BKC/audit/control.log")" '"action":"backup","status":"failed"'
unset BACKUP_FAIL

# Throttle (mirrors #59's upgrade throttle): bid1 above already claimed the 10-minute window —
# a fourth attempt right after is refused before the passphrase is even generated.
bid4="a0a0a0a0-0000-4000-8000-000000000004"
: >"$SELF_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid4" >"$BKC/req4.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req4.json" "$BKC" >/dev/null 2>&1
assert_contains "an immediate second backup attempt is throttled" \
    "$(jq -r .error "$BKC/results/$bid4.json")" "less than 10 minutes"
assert_eq "a throttled attempt never runs the child" "$(cat "$SELF_LOG")" ""

# The request schema itself cannot carry a passphrase — control_process_request's fixed key
# allowlist (id/action/config/actor/version/worker/changes/confirm) rejects any other field
# before the action even dispatches, so the container has no field to smuggle one through.
bid5="a0a0a0a0-0000-4000-8000-000000000005"
printf '{"id":"%s","action":"backup","actor":"admin","passphrase":"leaked"}\n' "$bid5" >"$BKC/req5.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req5.json" "$BKC" >/dev/null 2>&1
assert_contains "a request carrying a passphrase field is refused outright (unexpected keys)" \
    "$(jq -r .error "$BKC/results/$bid5.json")" "unexpected keys"

# Backstop: a kit whose runner was KILLED mid-TTL keeps a plaintext passphrase on /data. The next
# drain's control_redact_stale_kits must null it once past the TTL, while leaving a still-in-window
# kit and a non-kit result alone.
export CONTROL_BACKUP_KIT_TTL_S=20 # cutoff = max(2x, 120) = 120s
old_ts=$(($(date +%s) - 3600))     # an hour stale
now_ts=$(date +%s)                 # fresh
jq -n --argjson t "$old_ts" '{status:"applied",passphrase:"STRANDED-SECRET",archive:"a.enc",ts:$t}' >"$BKC/results/stale.json"
jq -n --argjson t "$now_ts" '{status:"applied",passphrase:"LIVE-SECRET",archive:"b.enc",ts:$t}' >"$BKC/results/fresh.json"
jq -n --argjson t "$old_ts" '{status:"applied",change_id:"c",ts:$t}' >"$BKC/results/other.json" # not a kit
run_sourced "$SANDBOX" control_redact_stale_kits "$BKC/results" >/dev/null 2>&1
assert_eq "a stranded kit passphrase (runner died mid-TTL) is redacted on the next drain" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/stale.json")" "null"
assert_eq "a kit still inside its window keeps its passphrase" \
    "$(jq -r '.passphrase' "$BKC/results/fresh.json")" "LIVE-SECRET"
assert_eq "a non-kit result is left untouched" \
    "$(jq -r '.change_id' "$BKC/results/other.json")" "c"

# The sweep is NOT the backup kit's alone (#1882). It used to look at `.passphrase` and nothing
# else, so the moment a second kit shape existed — the onion client-auth kit, which carries a
# remote-access credential rather than an archive passphrase — a runner killed mid-TTL would have
# stranded that one in plaintext on /data forever, silently, because the sweep would have read it
# as "not a kit". CONTROL_KIT_SECRET_FIELDS is the one list both redactors share; these rows fail
# against a sweep that keys on any single field, and the passphrase rows above are their firing
# control — if the sweep broke outright, those go red too and these are not read as the cause.
jq -n --argjson t "$old_ts" '{status:"applied",client_key:"STRANDED-KEY",
    torrc_line:"abcd:descriptor:x25519:STRANDED-KEY",onion_url:"http://abcd.onion",ts:$t}' \
    >"$BKC/results/stale-onion.json"
jq -n --argjson t "$now_ts" '{status:"applied",client_key:"LIVE-KEY",ts:$t}' >"$BKC/results/fresh-onion.json"
run_sourced "$SANDBOX" control_redact_stale_kits "$BKC/results" >/dev/null 2>&1
assert_eq "a stranded onion kit's client key is redacted too" \
    "$(jq -r '.client_key // "null"' "$BKC/results/stale-onion.json")" "null"
assert_eq "and its torrc line, which EMBEDS that key, with it" \
    "$(jq -r '.torrc_line // "null"' "$BKC/results/stale-onion.json")" "null"
assert_eq "the onion kit's non-secret fields survive the redaction" \
    "$(jq -r '.onion_url' "$BKC/results/stale-onion.json")" "http://abcd.onion"
assert_eq "an onion kit still inside its window keeps its key" \
    "$(jq -r '.client_key' "$BKC/results/fresh-onion.json")" "LIVE-KEY"
unset PITHEAD_SELF SELF_LOG PASS_LOG FAKE_ARCHIVE CONTROL_BACKUP_KIT_TTL_S bid1 bid2 bid3 bid4 bid5 pass1 old_ts now_ts

# ---------------------------------------------------------------------------
echo "== control channel: the dashboard onion's client key, handed over once (#1882) =="
# THE DEFECT THESE ROWS PIN. With Tor client authorisation on — the default, and MANDATORY whenever
# dashboard.control is on, because parse_and_validate_config refuses that pair without it — the
# published .onion does not answer a browser that has no client key. The key was printed by exactly
# one thing, the `onion-client-key` CLI verb, and an appliance has no shell to run it in. So an
# appliance operator who turned the onion on got an address that is published, shown in the
# dashboard header, and impossible to open, under a note naming a command they could not run.

ock_dir() { # <enabled> <address> <client_auth> <privkey> -> a dir with that .env and a control spool
    local d="$SANDBOX/ock-$1-$2-$3-$4"
    rm -rf "$d"
    mkdir -p "$d/control/results" "$d/control/audit"
    {
        echo "DASHBOARD_ONION_ENABLED=$1"
        echo "DASHBOARD_ONION_ADDRESS=$2"
        echo "DASHBOARD_ONION_CLIENT_AUTH=$3"
        echo "DASHBOARD_ONION_CLIENT_PRIVKEY=$4"
    } >"$d/.env"
    printf '%s' "$d"
}
ock_ok=$(ock_dir true abcd.onion true PRIVKEY123)
ock_off=$(ock_dir false abcd.onion true PRIVKEY123)
ock_noauth=$(ock_dir true abcd.onion false PRIVKEY123)
ock_unprov=$(ock_dir true placeholder true PRIVKEY123)
ock_nokey=$(ock_dir true abcd.onion true placeholder)

# --- onion_client_credential: ONE set of preconditions for both surfaces, so the CLI verb and the
# control verb cannot drift into disagreeing about whether there is a key. The success row is the
# firing control for the four refusals: without it, four "refuses" assertions stay green against a
# function that can only ever fail.
assert_eq "credential: address and key, tab-separated, when provisioned" \
    "$(run_sourced "$ock_ok" onion_client_credential)" "$(printf 'abcd.onion\tPRIVKEY123')"
assert_contains "credential: refuses when the onion is off" \
    "$(run_sourced "$ock_off" onion_client_credential)" "is not enabled"
assert_contains "credential: refuses when client-auth is off (password-only)" \
    "$(run_sourced "$ock_noauth" onion_client_credential)" "password-only"
assert_contains "credential: refuses while the ADDRESS is still a placeholder" \
    "$(run_sourced "$ock_unprov" onion_client_credential)" "not provisioned"
assert_contains "credential: refuses while the KEY is still a placeholder" \
    "$(run_sourced "$ock_nokey" onion_client_credential)" "not provisioned"
# The rc, not only the message: every caller branches on the status, and a function that printed a
# refusal and still returned 0 would hand that sentence to the operator AS the key.
run_sourced "$ock_ok" onion_client_credential >/dev/null
assert_rc "credential: rc 0 when there is a key" "$?" "0"
run_sourced "$ock_unprov" onion_client_credential >/dev/null
assert_rc "credential: rc 1 when there is not" "$?" "1"
assert_contains "the CLI verb refuses with that shared reason, not a second wording" \
    "$(run_sourced "$ock_unprov" onion_client_key 2>&1)" "not provisioned"
assert_contains "the CLI verb still prints both client forms when there IS a key" \
    "$(run_sourced "$ock_ok" onion_client_key 2>&1)" "abcd:descriptor:x25519:PRIVKEY123"

# --- control_onion_client_key, with its window held open. Shadowing control_kit_redact is what
# freezes it: a long TTL would make the verb sleep, and a short one would redact the kit before
# these rows could read what was written — and what was written is the point. The redaction itself
# is proved separately below, against the real function.
ock_id=a1a1a1a1-0000-4000-8000-0000000000a1
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$ock_ok" && source "$STACK" && set +e
    control_kit_redact() { :; }
    APP_GID="$(id -g)" CONTROL_BACKUP_KIT_TTL_S=0 control_onion_client_key "$ock_id" admin "$ock_ok/control"
) >/dev/null 2>&1
ock_kit="$ock_ok/control/results/$ock_id.json"
assert_eq "kit: Tor Browser's form is the bare private key" \
    "$(jq -r '.client_key' "$ock_kit" 2>/dev/null)" "PRIVKEY123"
# System Tor wants the address WITHOUT its .onion suffix. Getting this wrong produces a line Tor
# silently ignores, which reads to the operator as "the key does not work".
assert_eq "kit: system Tor's form drops the .onion suffix before the descriptor" \
    "$(jq -r '.torrc_line' "$ock_kit" 2>/dev/null)" "abcd:descriptor:x25519:PRIVKEY123"
assert_eq "kit: the address rides along, so the operator needs nothing else" \
    "$(jq -r '.status + " " + .onion_url' "$ock_kit" 2>/dev/null)" "applied http://abcd.onion"
# Same perms as the backup kit above, for the same reason: this file holds a remote-access
# credential for as long as its window is open.
assert_eq "kit: not world-readable while the window is open" \
    "$(stat -c '%a' "$ock_kit" 2>/dev/null || stat -f '%Lp' "$ock_kit" 2>/dev/null)" "640"
# THE COMPENSATING CONTROL. audit/ is mounted read-only into the container, so a reveal the
# operator did not ask for cannot be made invisible by whoever asked for it.
assert_contains "kit: every reveal is recorded in the audit log" \
    "$(cat "$ock_ok/control/audit/control.log" 2>/dev/null)" '"action":"onion-client-key","status":"applied"'

# The window really closes: the real function, TTL 0, redacting in band before the verb returns.
# That is what makes "shown once" true rather than aspirational.
ock_ttl_id=a1a1a1a1-0000-4000-8000-0000000000a2
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$ock_ok" && source "$STACK" && set +e
    APP_GID="$(id -g)" CONTROL_BACKUP_KIT_TTL_S=0 control_onion_client_key "$ock_ttl_id" admin "$ock_ok/control"
) >/dev/null 2>&1
ock_ttl_kit="$ock_ok/control/results/$ock_ttl_id.json"
assert_eq "kit: the client key is nulled once its window closes" \
    "$(jq -r '.client_key // "NULLED"' "$ock_ttl_kit" 2>/dev/null)" "NULLED"
assert_eq "kit: the torrc line — which EMBEDS the key — is nulled with it" \
    "$(jq -r '.torrc_line // "NULLED"' "$ock_ttl_kit" 2>/dev/null)" "NULLED"
assert_eq "kit: the address survives, so the card can still say WHICH onion" \
    "$(jq -r '.onion_url' "$ock_ttl_kit" 2>/dev/null)" "http://abcd.onion"

# A machine with nothing to hand over answers with the host's OWN reason. The operator who turned
# the onion on a minute ago must be told it is not provisioned yet, not shown an empty card.
ock_rej_id=a1a1a1a1-0000-4000-8000-0000000000a3
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$ock_unprov" && source "$STACK" && set +e
    APP_GID="$(id -g)" CONTROL_BACKUP_KIT_TTL_S=0 control_onion_client_key "$ock_rej_id" admin "$ock_unprov/control"
) >/dev/null 2>&1
ock_rej="$ock_unprov/control/results/$ock_rej_id.json"
assert_eq "rejection: an unprovisioned onion is refused, not answered blank" \
    "$(jq -r '.status' "$ock_rej" 2>/dev/null)" "rejected"
assert_contains "rejection: carries the host's own reason verbatim" \
    "$(jq -r '.error' "$ock_rej" 2>/dev/null)" "not provisioned"
assert_eq "rejection: carries no client_key field at all" \
    "$(jq -r 'has("client_key")' "$ock_rej" 2>/dev/null)" "false"
assert_contains "rejection: a refused reveal is audited too" \
    "$(cat "$ock_unprov/control/audit/control.log" 2>/dev/null)" '"action":"onion-client-key","status":"rejected"'

# --- dispatch. The verb is only reachable if control_process_request routes it; an unrouted action
# answers "unknown action", which would leave every row above green against a feature no request
# can start. The near-miss name is that row's firing control.
ock_disp_id=a1a1a1a1-0000-4000-8000-0000000000a4
ock_bogus_id=a1a1a1a1-0000-4000-8000-0000000000a5
printf '{"id":"%s","action":"onion-client-key","actor":"admin"}\n' "$ock_disp_id" >"$ock_ok/req.json"
printf '{"id":"%s","action":"onion-client-keyx","actor":"admin"}\n' "$ock_bogus_id" >"$ock_ok/req2.json"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$ock_ok" && source "$STACK" && set +e
    APP_GID="$(id -g)" CONTROL_BACKUP_KIT_TTL_S=0 control_process_request "$ock_ok/req.json" "$ock_ok/control"
    control_process_request "$ock_ok/req2.json" "$ock_ok/control"
) >/dev/null 2>&1
assert_eq "dispatch: the request reaches the verb, not the unknown-action arm" \
    "$(jq -r '.status' "$ock_ok/control/results/$ock_disp_id.json" 2>/dev/null)" "applied"
assert_contains "dispatch: a near-miss action name is still unknown (control)" \
    "$(jq -r '.error' "$ock_ok/control/results/$ock_bogus_id.json" 2>/dev/null)" "unknown action"

rm -rf "$ock_ok" "$ock_off" "$ock_noauth" "$ock_unprov" "$ock_nokey"
unset ock_ok ock_off ock_noauth ock_unprov ock_nokey ock_kit ock_ttl_kit ock_rej
unset ock_id ock_ttl_id ock_rej_id ock_disp_id ock_bogus_id
