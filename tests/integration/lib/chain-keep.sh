# shellcheck shell=bash
#
# Chain-node keep (#2639): monerod and tari stay running across a branch deploy and its restore
# when the branch leaves their definitions alone.
#
# Sourced by e2e.sh, which supplies on_bench/ok/warn/step, RESTORE_DIR and E2E_DIR. The decisions
# are pure functions, driven with no ssh and no docker by selftest-e2e-chain-keep.sh; the bench
# reads around them are thin.
#
# The e2e checkout and the baseline drive the one pinned Compose project, and both chain services
# bind-mount checkout-relative paths (./build/monero/bitmonero.conf.template, ./build/tari,
# ./data/clearnet-state). Compose resolves them to absolute paths and hashes them into each
# service's config, so an up from the other checkout recreates both nodes even when nothing about
# them changed. The deploy therefore runs with PITHEAD_KEEP_RUNNING (lib/pithead/01-lifecycle.sh),
# which leaves them out of the up, and then recreates only the ones this file finds changed. The
# restore needs no knob: a kept node is the baseline's own container, so the baseline's own up
# finds it current and leaves it be. Only `pithead down` ever stopped it there.
#
# "Unchanged" means all three of these match between RESTORE_DIR and E2E_DIR (operator ruling):
#   config  the service's `docker compose config`, image and build dropped, with each mount that is
#           inside the checkout and read-only or under build/ rewritten to one placeholder
#   files   the content of each of those rewritten mounts, so a branch that edits only an
#           entrypoint or a template is tested on it
#   image   the image ID, never the tag: a release baseline's :vX.Y.Z and the branch's :dev build
#           match only when they are the same object
# monerod also needs tor untouched by the deploy: its depends_on tor carries restart: true (#972),
# and an up that recreated tor without monerod in it would leave monerod on dead SOCKS connections.

CHAIN_SERVICES="monerod tari"
CHAIN_KEPT=""   # what the deploy left running from the baseline
CHAIN_BEFORE="" # snapshot before the deploy
CHAIN_MID=""    # snapshot when the restore starts, after the harness ran

# Input: `docker compose config --format json`. Args: $s the service, $d and $p the checkout as
# $PWD and as `pwd -P`. Output: {config, mounts}; mounts are {src, rel} for the content hash.
# shellcheck disable=SC2016 # a jq program: its $names are jq variables, not shell ones
CHAIN_NORMALIZE_JQ='
def rel($x): ($d + "/") as $a | ($p + "/") as $b
  | if ($x | startswith($a)) then "@CHECKOUT@/" + ($x | ltrimstr($a))
    elif ($x | startswith($b)) then "@CHECKOUT@/" + ($x | ltrimstr($b))
    else null end;
def hashed: .type == "bind" and rel(.source // "") != null
  and (.read_only == true or (rel(.source) | startswith("@CHECKOUT@/build/")));
. as $all | .services[$s] as $svc
| if $svc == null then error("no service " + $s) else . end
| { config: { service: ($svc | del(.image, .build)
                | .volumes = [ .volumes[]? | if hashed then .source = rel(.source) else . end ]),
              networks: (($all.networks // {}) | with_entries(select(.key as $k | ($svc.networks // {}) | has($k)))) },
    mounts: [ $svc.volumes[]? | select(hashed) | {src: .source, rel: rel(.source)} ] }'

# "config=<sha256> files=<sha256>" for one service as rendered in <dir>, or empty when it cannot be
# read. files= is "unreadable" when a mount's content could not be hashed. Hashes only: the config
# carries the node credentials, so it never leaves the box.
chain_fingerprint() { # <dir> <service>
    {
        printf 's=%q\nprog=%q\n' "$2" "$CHAIN_NORMALIZE_JQ"
        cat <<'FP'
set -o pipefail
norm=$(docker compose config --format json 2>/dev/null | jq -c --arg s "$s" --arg d "$PWD" --arg p "$(pwd -P)" "$prog" 2>/dev/null) || exit 1
config=$(printf '%s' "$norm" | jq -cS .config | sha256sum | cut -d' ' -f1)
files=$(printf '%s' "$norm" | jq -r '.mounts[] | [.src, .rel] | @tsv' | while IFS=$'\t' read -r src rel; do
    if [ -d "$src" ]; then (cd "$src" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) | sed "s|^|$rel |" || echo "$rel unreadable"
    elif [ -f "$src" ]; then h=$(sha256sum <"$src" | cut -d' ' -f1) && echo "$rel $h" || echo "$rel unreadable"
    else echo "$rel missing"; fi
done)
case "$files" in *" unreadable"*) files=unreadable ;; *) files=$(printf '%s' "$files" | sha256sum | cut -d' ' -f1) ;; esac
echo "config=$config files=$files"
FP
    } | on_bench "cd '$1' && bash -s" 2>/dev/null || true
}

# The image ID <dir>'s rendered config names for <service>; empty when it is not on the box.
chain_image_of() { # <dir> <service>
    on_bench "cd '$1' && ref=\$(docker compose config --format json 2>/dev/null | jq -r --arg s '$2' '.services[\$s].image // empty') && [ -n \"\$ref\" ] && docker image inspect --format '{{.Id}}' \"\$ref\" 2>/dev/null" 2>/dev/null || true
}

# One "<service> <container-id> <started-at> <image-id>" line per RUNNING chain service and tor.
chain_snapshot() {
    on_bench "for s in $CHAIN_SERVICES tor; do docker ps -q --filter label=com.docker.compose.project=pithead --filter label=com.docker.compose.service=\$s --filter status=running | head -n1 | xargs -r docker inspect --format \"\$s {{.Id}} {{.State.StartedAt}} {{.Image}}\"; done" 2>/dev/null || true
}

# Field <n> (2 id, 3 started-at, 4 image) of <service>'s line in a snapshot; empty when absent.
chain_snap_get() { # <snapshot> <service> <n>
    printf '%s\n' "$1" | awk -v s="$2" -v n="$3" '$1 == s { print $n; exit }'
}

# Pure. keep, or "recreate <what differs>". An unreadable or missing input never reads as a match.
chain_keep_verdict() { # <service> <baseline-fp> <branch-fp> <baseline-image> <branch-image> <tor-before> <tor-after>
    local why=""
    { [ -n "$2" ] && [ "$2" = "$3" ] && [ "${2#*files=unreadable}" = "$2" ]; } || why="definition"
    { [ -n "$4" ] && [ "$4" = "$5" ]; } || why="${why:+$why, }image"
    [ "$1" != monerod ] || { [ -n "$6" ] && [ "$6" = "$7" ]; } || why="${why:+$why, }tor"
    if [ -z "$why" ]; then echo keep; else echo "recreate $why"; fi
}

# Deploy the branch with the running chain services held out of the up, then recreate the ones
# whose definition, mounted files or image differ from the baseline's. Sets CHAIN_KEPT.
deploy_keeping_chain() {
    local held="" recreate="" svc verdict after
    CHAIN_BEFORE="$(chain_snapshot)" CHAIN_KEPT=""
    for svc in $CHAIN_SERVICES; do [ -z "$(chain_snap_get "$CHAIN_BEFORE" "$svc" 2)" ] || held="$held $svc"; done
    held="${held# }"
    [ -n "$held" ] || {
        on_bench "cd '$E2E_DIR' && ./pithead upgrade"
        return
    }
    on_bench "cd '$E2E_DIR' && PITHEAD_KEEP_RUNNING='$held' ./pithead upgrade" || return 1
    after="$(chain_snapshot)"
    # The held-out up built nothing for them; build monerod now so its image ID can be compared.
    case " $held " in *" monerod "*) on_bench "cd '$E2E_DIR' && docker compose build monerod >/dev/null 2>&1" || {
        warn "building the branch's monerod image failed in $E2E_DIR"
        return 1
    } ;;
    esac
    for svc in $held; do
        verdict="$(chain_keep_verdict "$svc" "$(chain_fingerprint "$RESTORE_DIR" "$svc")" "$(chain_fingerprint "$E2E_DIR" "$svc")" \
            "$(chain_snap_get "$CHAIN_BEFORE" "$svc" 4)" "$(chain_image_of "$E2E_DIR" "$svc")" \
            "$(chain_snap_get "$CHAIN_BEFORE" tor 2) $(chain_snap_get "$CHAIN_BEFORE" tor 3)" \
            "$(chain_snap_get "$after" tor 2) $(chain_snap_get "$after" tor 3)")"
        if [ "$verdict" = keep ]; then
            CHAIN_KEPT="${CHAIN_KEPT:+$CHAIN_KEPT }$svc"
            ok "chain: $svc unchanged by the branch — left running (container $(chain_snap_get "$CHAIN_BEFORE" "$svc" 2 | cut -c1-12))"
        else
            recreate="$recreate $svc"
            step "chain: $svc differs from the baseline (${verdict#recreate }) — recreating it from the branch"
        fi
    done
    [ -n "$recreate" ] || return 0
    on_bench "cd '$E2E_DIR' && ${CHAIN_KEPT:+PITHEAD_KEEP_RUNNING='$CHAIN_KEPT' }./pithead up"
}

# Restore side, in place of the old `pithead down`: record what the harness left running, and
# remove the containers of services the baseline does not define (a branch that adds a service),
# which the baseline's own up would otherwise leave running. Everything else is the baseline's up.
chain_restore_prepare() {
    local removed
    CHAIN_MID="$(chain_snapshot)"
    removed="$(on_bench "cd '$RESTORE_DIR' && known=\$(docker compose config --services 2>/dev/null) && [ -n \"\$known\" ] && docker ps -a --filter label=com.docker.compose.project=pithead --format '{{.ID}} {{.Label \"com.docker.compose.service\"}}' | while read -r id svc; do printf '%s\n' \"\$known\" | grep -qxF \"\$svc\" || { docker rm -f \"\$id\" >/dev/null && echo \"\$svc\"; }; done" 2>/dev/null || true)"
    [ -z "$removed" ] || step "removed service(s) the baseline does not define: $(printf '%s' "$removed" | tr '\n' ' ')"
}

# Pure. One "<verdict> <service>" line per chain service that ran before the deploy:
#   untouched  the same container, never restarted
#   restarted  the same container, started again (--lifecycle stops and starts monerod)
#   recreated  a different container; expected when the deploy or the harness recreated it
#   broken     a different container, though the deploy kept it and the harness left it alone:
#              the restore itself recreated a node it should not have touched
#   gone       not running now
grade_chain_restore() { # <kept> <before> <mid> <after>
    local svc before_id
    for svc in $CHAIN_SERVICES; do
        before_id="$(chain_snap_get "$2" "$svc" 2)"
        [ -n "$before_id" ] || continue
        if [ -z "$(chain_snap_get "$4" "$svc" 2)" ]; then
            echo "gone $svc"
        elif [ "$(chain_snap_get "$4" "$svc" 2)" = "$before_id" ]; then
            if [ "$(chain_snap_get "$4" "$svc" 3)" = "$(chain_snap_get "$2" "$svc" 3)" ]; then echo "untouched $svc"; else echo "restarted $svc"; fi
        elif case " $1 " in *" $svc "*) true ;; *) false ;; esac && [ "$(chain_snap_get "$3" "$svc" 2)" = "$before_id" ]; then
            echo "broken $svc"
        else
            echo "recreated $svc"
        fi
    done
}

# The restore proof's chain record. Returns 1 only on 'broken'; 'gone' is check 4's to fail.
chain_restore_proof() {
    local line rc=0
    [ -n "$CHAIN_BEFORE" ] || return 0
    while IFS= read -r line; do
        case "$line" in
        untouched\ *) ok "restore proof: ${line#* } is the same container, never restarted, as before the deploy" ;;
        restarted\ *) ok "restore proof: ${line#* } is the same container as before the deploy, restarted in place" ;;
        recreated\ *) step "restore proof: ${line#* } was recreated during this run (the branch changed it, or a phase did)" ;;
        broken\ *)
            warn "restore proof: ${line#* } was kept through the deploy and the harness, and the RESTORE recreated it."
            rc=1
            ;;
        gone\ *) warn "restore proof: ${line#* } ran before the deploy and is not running now." ;;
        esac
    done < <(grade_chain_restore "$CHAIN_KEPT" "$CHAIN_BEFORE" "$CHAIN_MID" "$(chain_snapshot)")
    return "$rc"
}
