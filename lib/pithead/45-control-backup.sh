# One-shot encrypted backup + one-time "emergency kit" (#908). Reuses stack_backup UNCHANGED
# (~L2793), encrypted ONLY — no request field can pick --no-encrypt (it stays CLI-only), and a
# failure to mint a passphrase refuses before anything is touched, never falls back to plaintext.
# The passphrase is generated HOST-SIDE (generate_node_password: the same 32-char-alnum strength
# already used for the local node RPC creds) and crosses to stack_backup only through its existing
# PITHEAD_BACKUP_PASSPHRASE env-var input — the same channel an unattended cron backup already
# uses — never argv (what the support bundle's redaction targets, #77) and never a file.
#
# One-time handoff lifecycle: the kit (passphrase + archive name + contents + created-at/`ts`)
# rides back through the SAME results/ leg every other verb uses, keyed by the request id — but
# results/ is mounted READ-ONLY into the dashboard container (#33's trust boundary: it can only
# ASK, via requests/), so the container can never itself delete or ack this file the way the
# first-boot wizard's handoff/handoff-ack does (that spool is mounted read-write end to end). The
# deliberate substitute here: a bounded, blocking TTL. Short enough that a stuck backup doesn't
# stall the single-threaded runner's other queued verbs for long; generous next to the dashboard's
# own long-poll window (CONTROL_WAIT_S) so an ordinary page load always sees it. Once it elapses
# the passphrase is overwritten with null — read or not, it is gone. The archive/filename/contents
# stay: it is ciphertext, useless without the passphrase, so it remains downloadable.
# ponytail: TTL, not a container->host ack request (a "backup-ack" verb through requests/ would be
# more precise but is a whole extra verb) — add one if this window proves too tight/loose live.
# EVERY field a one-time kit may carry that must not outlive its TTL. Named ONCE, as JSON so it can
# ride into jq as --argjson, because there are two redactors — the in-band one each kit runs when
# its window closes, and the reboot backstop below — and a field added to one but not the other is
# a wallet- or remote-access-grade secret left in plaintext on /data. `passphrase` is the backup
# kit's (#908); `client_key` and `torrc_line` are the onion client-auth kit's (#1882), and the
# torrc line is listed because it EMBEDS the key rather than merely describing it.
readonly CONTROL_KIT_SECRET_FIELDS='["passphrase","client_key","torrc_line"]'

# True if a result file still carries any unredacted one-time secret.
control_kit_has_secret() { # <kit-file>
    jq -e --argjson f "$CONTROL_KIT_SECRET_FIELDS" '. as $d | any($f[]; ($d[.] // "") | length > 0)' \
        "$1" >/dev/null 2>&1
}

# Null every one-time secret field a kit carries and replace its note. Rewrite-then-rename so a
# reader never sees a half-written kit, and a jq failure leaves the original standing rather than
# truncating it.
control_kit_redact() { # <kit-file> <replacement-note>
    local f="$1" note="$2" tmp
    tmp="$(dirname "$f")/.$(basename "$f").tmp"
    jq --argjson fields "$CONTROL_KIT_SECRET_FIELDS" --arg n "$note" '
        reduce $fields[] as $k (.; if has($k) then .[$k] = null else . end) | .note = $n' \
        "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f"
}

# Backstop for the one-time kits: null the secret in any kit JSON whose `ts` is older than the TTL
# but which still carries one — the case where the runner was killed during the self-redaction
# sleep (a reboot racing the window) and left a wallet- or remote-access-grade secret in plaintext
# on /data. Run at the top of every drain, so the fresh runner after such a reboot cleans it up. A
# generous margin over the TTL (2x, floor 120s) so this never races the in-band redaction of a kit
# whose window is still open.
control_redact_stale_kits() { # <results-dir>
    local results="$1" f now cutoff ts
    [ -d "$results" ] || return 0
    now=$(date +%s)
    cutoff=$((2 * ${CONTROL_BACKUP_KIT_TTL_S:-20}))
    [ "$cutoff" -lt 120 ] && cutoff=120
    for f in "$results"/*.json; do
        [ -f "$f" ] || continue
        # Cheap gate first: only kits that still hold a secret are candidates.
        control_kit_has_secret "$f" || continue
        ts=$(jq -r '.ts // 0' "$f" 2>/dev/null)
        [ "$((now - ts))" -ge "$cutoff" ] || continue
        control_kit_redact "$f" "The secret was shown once and is no longer available on this host — ask for it again if you did not save it."
    done
}

control_backup() { # <id> <actor> <control-dir>
    local id="$1" actor="$2" cdir="$3" rc=0
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "backup" "started"
    # Throttle (mirrors control_upgrade's #59 stamp): a compromised container flooding this verb
    # would repeatedly stop/start the whole mining stack, not just burn CPU — one attempt per 10
    # minutes, checked before the passphrase is even generated.
    local stamp="$cdir/staged/.backup-stamp"
    if [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"a backup was started less than 10 minutes ago — wait for it to finish, then retry.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "rejected"
        return 0
    fi
    { set +x; } 2>/dev/null # xtrace would print the passphrase assignment below
    local pass
    pass=$(generate_node_password)
    if [ -z "$pass" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"could not generate a backup passphrase — nothing was backed up.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "rejected"
        return 0
    fi
    touch "$stamp" 2>/dev/null || true # claim the throttle before the disruptive part starts
    control_write_result "$results" "$id" "$(jq -n '{status:"running",ts:(now|floor)}')"
    local self="${PITHEAD_SELF:-$0}" logf="$cdir/staged/.$id.log"
    # Run as a CHILD PROCESS, like control_lifecycle/control_commit's own re-invocations:
    # stack_backup's error() exits its whole process on failure, which must not take the drain
    # loop's other pending requests down with it.
    export PITHEAD_BACKUP_PASSPHRASE="$pass"
    "$self" backup -y >"$logf" 2>&1 || rc=$?
    unset PITHEAD_BACKUP_PASSPHRASE
    if [ "$rc" -ne 0 ]; then
        control_write_result "$results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "failed"
        rm -f "$logf"
        pass=""
        return 0
    fi
    local archive
    archive=$(sed -n 's/^\[pithead\] Backup written to: //p' "$logf" | tail -n1)
    rm -f "$logf"
    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"failed",error:"the backup ran but the archive could not be located afterward.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "failed"
        pass=""
        return 0
    fi
    # Place it on the ALREADY-shared results/ leg (#33) — no new bind mount, keyed by the same id
    # as its own result. Tighter perms than the rest of results/ (which relies on default,
    # effectively world-readable perms — fine, nothing there is a secret): root-owned,
    # group-readable by the dashboard's own uid/gid only (APP_UID/APP_GID, #255), because this
    # file briefly shares a directory with its own passphrase below.
    local fname dest
    fname=$(basename "$archive")
    dest="$results/$id.tar.gz.enc"
    mv "$archive" "$dest"
    chown "0:$APP_GID" "$dest" 2>/dev/null || true
    chmod 640 "$dest" 2>/dev/null || true
    (umask 077 && control_write_result "$results" "$id" "$(jq -n --arg p "$pass" --arg f "$fname" '
        {status:"applied", passphrase:$p, archive:$f,
         contents:["config.json","the stack .env (secrets)","Caddyfile, if present",
                   "the Tor onion-service key directory, if present","the dashboard database"],
         note:"This passphrase is shown once and cannot be recovered — save it now.",
         ts:(now|floor)}')")
    pass=""
    chown "0:$APP_GID" "$results/$id.json" 2>/dev/null || true
    chmod 640 "$results/$id.json" 2>/dev/null || true
    control_audit "$auditf" "$id" "$actor" "backup" "applied"
    # The blocking TTL described above the function. Overridable so tests don't sit through it.
    sleep "${CONTROL_BACKUP_KIT_TTL_S:-20}"
    control_kit_redact "$results/$id.json" "The passphrase was shown once and is no longer available on this host — back up again if you did not save it."
}

# `onion-client-key` (#1882): hand the operator the Tor client-auth credential for the dashboard
# onion, as a one-time kit on the same results/ leg the backup kit uses.
#
# WHY THIS EXISTS. With client authorisation on — which is the default, and which the validator
# REQUIRES whenever the control channel is on (28-parse-and-validate-config.sh) — the .onion does
# not answer a browser that has no client key. The key is in the host's .env and was printed by
# exactly one thing: the `onion-client-key` CLI verb. An appliance has no shell to run it in, so
# turning the onion on there produced an address that is published, shown in the dashboard header,
# and impossible to open. This is the surface that closes that.
#
# WHY THE KEY MAY CROSS INTO THE CONTAINER AT ALL, given that #1880 deliberately keeps it out of
# the dashboard's environment. That ruling stands and is untouched: the steady-state container
# still holds the enabled flag, the address and the client-auth BOOLEAN, and nothing else, so a
# compromised container has no standing credential to leak. What this verb adds is a moment, not a
# mount. And it adds no CAPABILITY a compromised container did not already have: `backup` puts an
# encrypted archive of the whole machine — its own `contents` list says "the stack .env (secrets)"
# — on this same read-only leg beside its passphrase, in one request. Narrowing the honest
# operator's path from "export every secret on the machine" to "show me this one line" is a
# reduction in blast radius, not an increase.
#
# THE COMPENSATING CONTROL IS THE AUDIT LINE, not the typed friction: every reveal is recorded in
# audit/, which is mounted READ-ONLY into the container, so a reveal the operator did not ask for
# cannot be made invisible by the party that asked for it.
#
# No throttle, deliberately: unlike `backup` this starts no disruptive work, and a throttle would
# not help against the only attacker that matters here — one read is all a compromised container
# needs, and the second press is the honest operator who closed the card too early.
# ponytail: one shared client key for every reader. Tor v3 supports a file per authorized client,
# so a phone could get its own revocable key (org#6's QR onboarding) — add that when there is a
# second reader to revoke, not before.
control_onion_client_key() { # <id> <actor> <control-dir>
    local id="$1" actor="$2" cdir="$3"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "onion-client-key" "started"
    { set +x; } 2>/dev/null # xtrace would print the key below
    local cred onion privkey
    if ! cred=$(onion_client_credential); then
        control_write_result "$results" "$id" "$(jq -n --arg e "$cred" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "onion-client-key" "rejected"
        return 0
    fi
    IFS=$'\t' read -r onion privkey <<<"$cred"
    # Same perms as the backup kit, for the same reason: root-owned, readable only by the
    # dashboard's own uid/gid, because this file holds a secret while its window is open.
    (umask 077 && control_write_result "$results" "$id" "$(jq -n --arg o "$onion" --arg k "$privkey" '
        {status:"applied", onion_url:("http://" + $o), client_key:$k,
         torrc_line:(($o | sub("\\.onion$"; "")) + ":descriptor:x25519:" + $k),
         note:"This is a PRIVATE key and is shown once. Paste it into Tor Browser when it asks for the onion key, or put the torrc line in your ClientOnionAuthDir.",
         ts:(now|floor)}')")
    chown "0:$APP_GID" "$results/$id.json" 2>/dev/null || true
    chmod 640 "$results/$id.json" 2>/dev/null || true
    control_audit "$auditf" "$id" "$actor" "onion-client-key" "applied"
    privkey=""
    cred=""
    sleep "${CONTROL_BACKUP_KIT_TTL_S:-20}"
    control_kit_redact "$results/$id.json" "The client key was shown once and is no longer available on this host — ask for it again if you did not save it."
}
