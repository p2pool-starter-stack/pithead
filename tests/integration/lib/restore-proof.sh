# shellcheck shell=bash
#
# The restore proof (#971, #1085) and the image-identity check that goes with it (#272, restore side).
#
# Sourced by e2e.sh, which supplies on_bench/ok/warn/step, RESTORE_DIR, E2E_DIR and
# env_bake_verdict/control_units_verdict (lib.sh). Split out of e2e.sh rather than written there:
# the classifier below has to be drivable with no ssh and no docker, because that is the tier its
# mutation proof runs at (selftest-e2e-restore-proof.sh), and e2e.sh is at its file budget.
#
# The proof answers one question the rest of the harness cannot: after the EXIT trap has put the
# box back, is the box actually back? A restore that half-worked looks exactly as healthy as one
# that worked — that is the #971 incident, and the image check below is the same shape one layer
# further in.

# What the live stack was RUNNING, by service, before this run touched anything, and what
# deploy_branch then built. Both are image IDs, not tags: the defect they exist to catch is a tag
# that MOVED, so the tag cannot be the instrument. Empty means "not captured" — a skip, never a pass.
BASELINE_IMAGES=""
# Was pithead-egress.service (#2460) on the bench before this run? `up`/`upgrade` install it on any
# DIY host, the bench included, so a run that found none must leave none: the bench is shared, and
# an unrecorded unit is drift. present | absent; empty = never read, which the restore refuses.
EGRESS_UNIT_BEFORE=""
# The same record for pithead-egress.timer and its pithead-egress-check.service (#2599).
EGRESS_CHECK_BEFORE=""

egress_boot_unit_state() { # [unit] -> present | absent | "" (the bench could not be asked)
    on_bench "if systemctl cat ${1:-pithead-egress.service} >/dev/null 2>&1; then echo present; else echo absent; fi" 2>/dev/null || true
}

# The egress check pair (#2599), restored on the same rule as the boot unit below.
restore_egress_check_units() {
    case "$EGRESS_CHECK_BEFORE" in
    present) return 0 ;;
    absent) ;;
    *)
        warn "restore proof: whether pithead-egress.timer predates this run was never recorded, so the restore cannot say it left the bench as found (#2599)."
        return 1
        ;;
    esac
    on_bench "sudo systemctl disable --now pithead-egress.timer >/dev/null 2>&1; sudo rm -f /etc/systemd/system/pithead-egress.timer /etc/systemd/system/pithead-egress-check.service; sudo systemctl daemon-reload" >/dev/null 2>&1 || true
    if [ "$(egress_boot_unit_state pithead-egress.timer)" = absent ] &&
        [ "$(egress_boot_unit_state pithead-egress-check.service)" = absent ]; then
        ok "restore proof: pithead-egress.timer and its check removed — no trace of this run's egress check on the bench (#2599)"
        return 0
    fi
    warn "restore proof: pithead-egress.timer or pithead-egress-check.service is still on the bench after the restore, and neither was there before this run (#2599)."
    return 1
}

# Put the boot unit back the way the run found it and prove it. A unit that predates the run is the
# baseline's own and stays. The live DOCKER-USER rules are left alone either way: they are the
# baseline stack's own firewall, which the restore's apply has just reinstalled.
restore_egress_boot_unit() {
    case "$EGRESS_UNIT_BEFORE" in
    present)
        # Said out loud: a unit a cancelled run left behind also reads as "present", and a silent
        # pass here would bury that drift.
        step "restore proof: pithead-egress.service was already on the bench before this run — left in place, not removed (#2460)"
        return 0
        ;;
    absent) ;;
    *)
        warn "restore proof: whether pithead-egress.service predates this run was never recorded, so the restore cannot say it left the bench as found (#2460)."
        return 1
        ;;
    esac
    on_bench "sudo systemctl disable --now pithead-egress.service >/dev/null 2>&1; sudo rm -f /etc/systemd/system/pithead-egress.service; sudo systemctl daemon-reload" >/dev/null 2>&1 || true
    if [ "$(egress_boot_unit_state)" = absent ] &&
        on_bench "! systemctl show -p Wants --value docker.service | grep -q pithead-egress" >/dev/null 2>&1; then
        ok "restore proof: pithead-egress.service removed — no trace of this run's boot unit on the bench (#2460)"
        return 0
    fi
    warn "restore proof: pithead-egress.service is still on the bench after the restore, and it was not there before this run (#2460)."
    return 1
}

# The image OBJECT each running service is on. `docker ps` scopes it to the one pinned Compose
# project, so this reads the live stack whichever checkout last drove it. A re-tag does not move an
# image ID; only a rebuild or a different image does.
stack_image_census() { # -> sorted "<service>=<image-id>" lines; empty when no stack is running
    on_bench "docker ps -q --filter label=com.docker.compose.project=pithead 2>/dev/null |
        xargs -r docker inspect --format '{{index .Config.Labels \"com.docker.compose.service\"}}={{.Image}}' 2>/dev/null |
        sort" 2>/dev/null || true
}

# Read every live container, including duplicates and late scenario recreations.
stack_restore_census() {
    on_bench "bash -s" <<'PROBE'
ids=$(docker ps -q --filter label=com.docker.compose.project=pithead) || exit 1
while IFS= read -r id; do
    [ -n "$id" ] || continue
    service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id" && printf '.') || exit 1
    service=${service%$'\n'.}
    image=$(docker inspect --format '{{.Image}}' "$id") || exit 1
    owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id" && printf '.') || exit 1
    owner=${owner%$'\n'.}
    [[ "$service" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ && "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "invalid Compose identity on $id" >&2; exit 1; }
    case "$owner" in *'|'*|*$'\n'*) echo "invalid Compose owner on $id" >&2; exit 1 ;; esac
    printf '%s=%s|%s\n' "$service" "$image" "$owner"
done <<<"$ids"
PROBE
}

# Resolve the baseline checkout's Compose image references to image objects, not moving tags.
declared_image_census() {
    on_bench "cd '$RESTORE_DIR' && bash -s" <<'PROBE'
set -o pipefail
docker compose config --format json | jq -r '.services | to_entries[] | [.key, .value.image] | @tsv' |
while IFS="$(printf '\t')" read -r service image; do
    id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null) || id=missing
    printf '%s=%s\n' "$service" "$id"
done
PROBE
}

# A different image ID is not evidence of a baseline rebuild: the branch can recreate a
# container after its first census. Check the actual baseline declaration and Compose owner.
grade_restore_identity() { # <baseline> <live-container-census> <declared> <test-dir>
    local svc image expected owner entry seen
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        svc="${svc%%=*}"
        expected="$(census_get "$3" "$svc")"
        seen=0
        while IFS= read -r entry; do
            case "$entry" in "$svc="*) ;; *) continue ;; esac
            seen=$((seen + 1))
            image="${entry#*=}"
            owner="${image#*|}"
            image="${image%%|*}"
            if [ -z "$image" ] || [ -z "$expected" ] || [ -z "$owner" ] || [ "$owner" = '<no value>' ]; then
                printf 'unproved %s\n' "$svc"
            elif [ "$owner" = "$4" ]; then
                printf 'test-checkout %s\n' "$svc"
            elif [ "$image" != "$expected" ]; then
                printf 'wrong-image %s\n' "$svc"
            else
                printf 'verified %s\n' "$svc"
            fi
        done <<<"$2"
        [ "$seen" -gt 0 ] || printf 'unproved %s\n' "$svc"
        [ "$seen" -le 1 ] || printf 'duplicate %s\n' "$svc"
    done <<<"$1"
    while IFS= read -r entry; do
        svc="${entry%%=*}"
        [ -n "$svc" ] || continue
        printf '%s\n' "$1" | cut -d= -f1 | grep -qxF -- "$svc" && continue
        printf 'unexpected-service %s\n' "$svc"
    done <<<"$2"
}

# Recreate only containers that still belong to the test checkout; the kept chain nodes
# retain their container IDs when they already belong to the baseline (#2639).
recreate_test_checkout_containers() {
    on_bench "cd '$RESTORE_DIR' && E2E_DIR='$E2E_DIR' bash -s" <<'PROBE'
ids=$(docker ps -aq --filter label=com.docker.compose.project=pithead) || { echo 'docker ps failed during restore' >&2; exit 1; }
allowed=$(docker compose config --services) || { echo 'docker compose config --services failed during restore' >&2; exit 1; }
services=()
while IFS= read -r id; do
    [ -n "$id" ] || continue
    label=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id") || { echo "docker inspect failed for $id" >&2; exit 1; }
    service="${label%%|*}"
    [ "${label#*|}" = "$E2E_DIR" ] || continue
    if [[ "$service" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && grep -qxF -- "$service" <<<"$allowed"; then
        services+=("$service")
    else
        echo "Removing test-checkout-only container $id ($service)"
        docker rm -f "$id" || { echo "docker rm -f failed for $id ($service)" >&2; exit 1; }
    fi
done <<<"$ids"
[ "${#services[@]}" -gt 0 ] || exit 0
printf 'Recreating test-checkout services from baseline: %s\n' "${services[*]}"
docker compose up -d --no-deps --force-recreate "${services[@]}" || {
    printf 'docker compose up --force-recreate failed for %s\n' "${services[*]}" >&2
    exit 1
}
PROBE
}

# One service's image ID out of a census. Empty when the census does not carry that service.
census_get() { # <census> <service>
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# Restore proof (#971): after the restore brings the baseline back up, prove the LIVE stack
# actually runs RESTORE_DIR's on-disk config. A pre-#921 e2e run once left the containers on
# harness-rendered creds while the on-disk .env kept the real ones — internally consistent, so it
# mined and looked healthy for a day, while every host-side RPC probe 401ed. Five checks:
#   1. The credential marker baked into the running dashboard container (docker inspect) is the
#      same line as the on-disk .env's — env_bake_verdict (lib.sh) prints verdict words only,
#      never values.
#   2. monerod answers a host-side get_info with the on-disk creds — the exact probe the incident
#      broke. Only .status is required (sync may still be re-confirming); polled briefly because
#      the containers were just recreated. The probe script travels over ssh stdin (bash -s), so
#      the creds stay on the box and the remote command string carries no shell parens.
#   3. The box-global control units still name RESTORE_DIR (#1085). deploy_branch's `pithead
#      upgrade` repoints them at E2E_DIR, and the hardening phase's teardown deletes them outright
#      when it owns them — either way the live dashboard's config edits and one-click upgrades
#      queue into a spool nothing watches, while every other signal here still reads healthy.
#      The verdict comes from RESTORE_DIR's OWN doctor, run from RESTORE_DIR. That is not a
#      preference: check_control_units compares the installed units' ExecStart against $PWD, and
#      `pithead` cd's to the directory of the binary you invoke (SCRIPT_DIR, pithead:100) — so the
#      BRANCH's copy would compare against E2E_DIR and print the OK verdict on exactly the
#      stranded box this check exists to catch. It needs RESTORE_DIR on v1.19.2+, the release that
#      added the check; anything older classifies as no-check and FAILS rather than passing quietly.
#   4. Every live container runs the baseline-declared image and none names the test checkout.
#   5. monerod and tari are the same containers they were before the deploy, when the branch left
#      them unchanged (#2639, chain-keep.sh). Recorded per node; red only when the restore itself
#      recreated or restarted a node that the deploy kept and the harness left as the baseline's.
# Returns 0 when all five hold.
RESTORE_PROOF_VAR="MONERO_NODE_PASSWORD"
# shellcheck disable=SC2034  # CONTROL_PROOF_FAILED is declared and read by e2e.sh, which sources
# this file; it is set here because this is where the control-channel verdict is graded.
verify_restore_proof() {
    local prc=0 disk cid baked="" verdict
    disk="$(on_bench "grep -E '^${RESTORE_PROOF_VAR}=' '$RESTORE_DIR/.env' 2>/dev/null | head -n1" || true)"
    cid="$(on_bench "docker ps -q --filter label=com.docker.compose.project=pithead --filter label=com.docker.compose.service=dashboard 2>/dev/null | head -n1" || true)"
    [ -n "$cid" ] && baked="$(on_bench "docker inspect --format '{{json .Config.Env}}' '$cid' 2>/dev/null | jq -r '.[]'" || true)"
    verdict="$(env_bake_verdict "$RESTORE_PROOF_VAR" "$disk" "$baked")"
    if [ "$verdict" = "match" ]; then
        ok "restore proof: dashboard container env matches the on-disk .env ($RESTORE_PROOF_VAR)"
    else
        warn "restore proof: $RESTORE_PROOF_VAR baked into the live dashboard container vs $RESTORE_DIR/.env: $verdict"
        prc=1
    fi

    local out deadline=$(($(date +%s) + 60))
    while :; do
        out="$(
            on_bench "cd '$RESTORE_DIR' && bash -s" <<'PROBE'
u=$(grep -E '^MONERO_NODE_USERNAME=' .env 2>/dev/null | cut -d= -f2-)
p=$(grep -E '^MONERO_NODE_PASSWORD=' .env 2>/dev/null | cut -d= -f2-)
url=$(grep -E '^MONERO_RPC_URL=' .env 2>/dev/null | cut -d= -f2-)
[ -n "$url" ] || url="http://127.0.0.1:18081"
if [ -n "$u" ]; then body=$(printf 'user = %s\n' "$(printf '%s:%s' "$u" "$p" | jq -Rs .)" | curl -fsS --max-time 8 --digest -K - "$url/get_info" 2>/dev/null)
else body=$(curl -fsS --max-time 8 "$url/get_info" 2>/dev/null); fi
printf '%s' "$body" | jq -e '.status=="OK"' >/dev/null 2>&1 && echo rpc-ok || echo rpc-fail
PROBE
        )" || true
        if [ "$out" = "rpc-ok" ]; then
            ok "restore proof: host-side get_info answers with the on-disk creds"
            break
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            warn "restore proof: host-side get_info with the on-disk creds did NOT answer within 60s — the live monerod may be running different creds than $RESTORE_DIR/.env"
            prc=1
            break
        fi
        sleep 10
    done

    # 3. The control units must still name RESTORE_DIR (#1085). Grep the verdict, never doctor's
    #    exit code — it is 1 on ANY dr_fail, so an unrelated failure elsewhere would swamp this.
    #    It runs AFTER restore_all's `apply -y`, which converges the units (v1.19.2+), so on the
    #    ordinary #1085 path the strand is already repaired: this arm proves the box was LEFT
    #    working, it does not detect the strand (CONTROL_VERDICT_BEFORE and run.sh's ExecStart
    #    assertion do). Alone it catches a pithead too old to converge (no-check), a disabled
    #    channel where apply leaves stray units, and strands this run did not cause.
    local doc verdict_line
    doc="$(on_bench "cd '$RESTORE_DIR' && ./pithead doctor 2>/dev/null" || true)"
    verdict_line="$(printf '%s\n' "$doc" | awk '/^Dashboard control channel:/{getline; print; exit}')"
    case "$(control_units_verdict "$doc")" in
    on-target)
        # The units name the right directory. That is text; `enabled` is behaviour, and
        # provision_control_runner's `systemctl enable --now` is warn-only, so apply can return 0
        # with correctly-named units that will never fire.
        if on_bench "systemctl is-enabled pithead-control.path >/dev/null 2>&1"; then
            ok "restore proof: the control runner units point at $RESTORE_DIR, and the path unit is enabled"
        else
            warn "restore proof: the control units name $RESTORE_DIR but pithead-control.path is NOT enabled — correctly addressed and never fired."
            warn "  Repair on the box: sudo systemctl enable --now pithead-control.path"
            CONTROL_PROOF_FAILED=1
        fi
        ;;
    disabled)
        # NOT a pass. `apply` leaves the units alone when control is disabled, so this is the one
        # state in which a strand SURVIVES the restore. Look for the leftovers directly.
        if on_bench "grep -qsF 'ExecStart=$E2E_DIR/pithead' /etc/systemd/system/pithead-control.service"; then
            warn "restore proof: the control channel is disabled in $RESTORE_DIR's config, and the box-global units still name the e2e checkout ($E2E_DIR). A disabled apply does not clean them up."
            warn "  Repair on the box: sudo rm -f /etc/systemd/system/pithead-control.{path,service} && sudo systemctl daemon-reload"
            CONTROL_PROOF_FAILED=1
        else
            ok "restore proof: control channel disabled in $RESTORE_DIR, and no unit names the e2e checkout"
        fi
        ;;
    not-live)
        warn "restore proof: $RESTORE_DIR is not the live install by its own reckoning — doctor declined to grade its control channel. Units NOT proven."
        warn "  doctor said: ${verdict_line:-<no verdict line>}"
        ;;
    no-check)
        warn "restore proof: $RESTORE_DIR's doctor printed no control-channel verdict — that pithead predates the check (v1.19.2), or the box has no systemd. On a pre-v1.19.2 install the restore's own apply cannot converge the units either, so assume the box IS stranded."
        warn "  Check by hand: systemctl cat pithead-control.service"
        CONTROL_PROOF_FAILED=1
        ;;
    *)
        warn "restore proof: the control runner units do NOT point at $RESTORE_DIR — the live dashboard's config changes and one-click upgrades queue into a spool nothing reads, with nothing reporting a fault."
        warn "  doctor said: ${verdict_line:-<no verdict line>}"
        CONTROL_PROOF_FAILED=1
        ;;
    esac

    # Compare every live container with the baseline declaration and reject checkout residue.
    local now_images line identity declared live residue
    now_images="$(stack_image_census)"
    if [ -z "$BASELINE_IMAGES" ]; then
        warn "restore proof: image identity NOT CHECKED — no baseline census was taken (nothing was running at preflight)."
        prc=1
    elif [ -z "$now_images" ]; then
        warn "restore proof: image identity NOT CHECKED — no stack is running to census now."
        prc=1
    else
        declared="$(declared_image_census)" || declared=""
        live="$(stack_restore_census)" || live=""
        identity="$(grade_restore_identity "$BASELINE_IMAGES" "$live" "$declared" "$E2E_DIR")"
        while IFS= read -r line; do
            case "$line" in
            verified\ *) ;;
            *)
                warn "restore proof: $line; baseline image or Compose owner not proved"
                prc=1
                ;;
            esac
        done <<<"$identity"
        residue="$(on_bench "docker ps -a --filter label=com.docker.compose.project=pithead --filter label=com.docker.compose.project.working_dir='$E2E_DIR' --format '{{.Label \"com.docker.compose.service\"}}'")" || {
            warn "restore proof: could not inspect stopped test-checkout containers"
            prc=1
        }
        if [ -n "$residue" ]; then
            warn "restore proof: test-checkout containers remain (including stopped): $residue"
            prc=1
        fi
    fi
    chain_restore_proof || prc=1
    restore_egress_boot_unit || prc=1
    restore_egress_check_units || prc=1
    return "$prc"
}
