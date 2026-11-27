# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== black-box: apply stages the Tari wallet sidecar until publication (#3875) =="

build_val_sandbox
AS="$SANDBOX/apply-sidecar"
rm -rf "$AS"
cp -R "$V" "$AS"
AS_LOCK="$AS/apply.lock"
AS_LOG="$AS/publish.log"
AS_SECRET="$AS/data/tari-wallet-secret.env"

cat >"$AS/bin/mv" <<'EOF'
#!/usr/bin/env bash
source=""
target=""
for arg; do
    case "$arg" in
    -- | -*) ;;
    *)
        [ -n "$source" ] || source="$arg"
        target="$arg"
        ;;
    esac
done
[ "${PUBLISH_FAIL:-}" != stage-directory ] || [[ "$target" != *.tari-wallet-secret ]] || {
    mkdir -p "$target" || exit 1
    case "$target" in
    /*) stage_directory="$target" ;;
    *) stage_directory="$PWD/$target" ;;
    esac
    printf '%s\n' "$stage_directory" >"$STAGE_DIR_OUT" || exit 1
}
case "$target" in
"$PUBLISH_ENV") label=env ;;
"$PUBLISH_SECRET") label=sidecar ;;
*) exec /bin/mv "$@" ;;
esac
if flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null; then state=free; else state=held; fi
printf '%s %s\n' "$label" "$state" >>"$PUBLISH_LOG"
[ "${PUBLISH_FAIL:-}" != "$label" ] || exit 1
if [ "${PUBLISH_FAIL:-}" = sidecar-and-rollback ]; then
    [ "$label" != sidecar ] || exit 1
    [ "$label" != env ] || [[ "$source" != *.previous ]] || exit 1
fi
exec /bin/mv "$@"
EOF
chmod +x "$AS/bin/mv"

as_config() { # <Tari payout address> [mode]
    jq -n --arg monero "$VALID_PRIMARY" --arg tari "$1" --arg mode "${2:-local}" \
        '{monero:{mode:"local",wallet_address:$monero,node_username:"u",node_password:"p"},
          tari:{wallet_address:$tari,mode:$mode},p2pool:{pool:"mini"},dashboard:{secure:false}}' >"$AS/config.json"
}
as_apply() {
    (cd "$AS" && PITHEAD_LOCK_FILE="$AS_LOCK" \
        PUBLISH_ENV=.env PUBLISH_SECRET="$AS_SECRET" PUBLISH_LOG="$AS_LOG" \
        PUBLISH_FAIL="${AS_PUBLISH_FAIL:-0}" \
        STAGE_DIR_OUT="$AS/stage-directory.path" \
        DOCKER_LOG="$AS/docker.log" PATH="$AS/bin:$PATH" ./pithead apply "$@" 2>&1)
}
as_staged() {
    find "$AS" -maxdepth 1 -name '.env.new.*' -print
}
as_start_confirm() {
    rm -f "$AS/input" "$AS/async.log" "$AS/async.rc"
    mkfifo "$AS/input"
    exec 8<>"$AS/input"
    (
        as_apply <"$AS/input" >"$AS/async.log"
        printf '%s\n' "$?" >"$AS/async.rc"
    ) &
    AS_PID=$!
    AS_WAIT=0
    while ! grep -q 'Confirm by typing' "$AS/async.log" 2>/dev/null && kill -0 "$AS_PID" 2>/dev/null && [ "$AS_WAIT" -lt 200 ]; do
        sleep 0.05
        AS_WAIT=$((AS_WAIT + 1))
    done
    if grep -q 'Confirm by typing' "$AS/async.log" 2>/dev/null; then
        ok "revision race reaches the typed confirmation before the edit"
    else
        bad "revision race reaches the typed confirmation before the edit" "the bounded poll saw no prompt"
    fi
}
as_finish_confirm() { # <reply>
    printf '%s\n' "$1" >&8
    exec 8>&-
    wait "$AS_PID"
    AS_RC=$(cat "$AS/async.rc" 2>/dev/null)
}

seed_env
cp "$V/.env" "$AS/.env"
as_config "$VALID_TARI"
: >"$AS_LOG"
out="$(as_apply -y)"
assert_rc "sidecar fixture baseline applies" "$?" 0
printf 'LIVE-SIDECAR-MARKER\n' >"$AS_SECRET"
cp "$AS_SECRET" "$AS/live.expected"
cp "$AS/.env" "$AS/env.expected"
as_config "$VALID_TARI_SINGLE"
cp "$AS/config.json" "$AS/config.expected"
AS_SUFFIX="${VALID_TARI_SINGLE: -8}"

out="$(printf 'wrongend\n' | as_apply)"
assert_rc "wrong Tari suffix cancels cleanly" "$?" 0
assert_contains "wrong Tari suffix reports cancellation" "$out" "Apply cancelled"
assert_rc "typed cancellation keeps the live sidecar byte-identical" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
assert_eq "typed cancellation removes all staging artifacts" "$(as_staged)" ""
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"

rm -f "$AS_SECRET"
out="$(printf 'wrongend\n' | as_apply)"
assert_rc "typed cancellation with no live sidecar exits cleanly" "$?" 0
assert_eq "typed cancellation with no live sidecar keeps it absent" "$([ -e "$AS_SECRET" ] && echo present || echo absent)" absent
assert_eq "typed cancellation with no live sidecar removes all staging artifacts" "$(as_staged)" ""
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"

out="$(as_apply </dev/null)"
assert_rc "EOF at the Tari confirmation cancels cleanly" "$?" 0
assert_contains "EOF at the Tari confirmation reports cancellation" "$out" "Apply cancelled"
assert_rc "EOF cancellation keeps the live sidecar byte-identical" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
assert_eq "EOF cancellation removes all staging artifacts" "$(as_staged)" ""
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"

as_config "$VALID_TARI" off
out="$(printf 'n\n' | as_apply)"
assert_rc "generic confirmation cancellation exits cleanly" "$?" 0
assert_contains "generic confirmation cancellation reports cancellation" "$out" "Apply cancelled"
assert_rc "generic confirmation cancellation keeps the live sidecar byte-identical" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
assert_eq "generic confirmation cancellation removes all staging artifacts" "$(as_staged)" ""
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"

out="$(as_apply --dry-run --porcelain)"
assert_rc "sidecar dry-run succeeds" "$?" 0
assert_rc "dry-run keeps the live sidecar byte-identical" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
assert_eq "dry-run leaves no apply staging artifacts" "$(as_staged)" ""
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"

: >"$AS_LOG"
: >"$AS/stage-directory.path"
AS_PUBLISH_FAIL="stage-directory"
out="$(as_apply -y)"
stage_directory_rc=$?
unset AS_PUBLISH_FAIL
stage_directory=$(cat "$AS/stage-directory.path")
assert_rc "a planted staged-sidecar directory aborts apply" "$stage_directory_rc" 1
assert_rc "a planted staged-sidecar directory keeps the live environment" "$(
    cmp -s "$AS/.env" "$AS/env.expected"
    echo $?
)" 0
assert_rc "a planted staged-sidecar directory keeps the live sidecar" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
if [ -d "$stage_directory" ]; then
    ok "the planted staged-sidecar directory reached the renderer"
else
    bad "the planted staged-sidecar directory reached the renderer" "the mv probe recorded no directory"
fi
assert_eq "no secret temp is moved inside the planted staging directory" \
    "$(find "$stage_directory" -mindepth 1 -print 2>/dev/null)" ""
assert_eq "a rejected staged-sidecar directory leaves no secret temp file" \
    "$(find "$AS/data" -maxdepth 1 -name '.tari-wallet-secret.*' -print)" ""
[ -n "$stage_directory" ] && rmdir "$stage_directory"
assert_eq "removing the planted directory leaves no apply staging artifacts" "$(as_staged)" ""
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"

: >"$AS_LOG"
AS_PUBLISH_FAIL="env"
out="$(as_apply -y)"
env_publish_fail_rc=$?
unset AS_PUBLISH_FAIL
assert_rc "environment publication failure aborts apply" "$env_publish_fail_rc" 1
assert_contains "failed environment publication held the mutation lock" "$(cat "$AS_LOG")" "env held"
assert_rc "environment publication failure keeps the live environment" "$(
    cmp -s "$AS/.env" "$AS/env.expected"
    echo $?
)" 0
assert_rc "environment publication failure keeps the live sidecar" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
assert_eq "environment publication failure cleans all staging artifacts" "$(as_staged)" ""
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"

: >"$AS_LOG"
AS_PUBLISH_FAIL="sidecar"
out="$(as_apply -y)"
sidecar_publish_fail_rc=$?
unset AS_PUBLISH_FAIL
assert_rc "sidecar publication failure aborts apply" "$sidecar_publish_fail_rc" 1
assert_contains "failed sidecar publication held the mutation lock" "$(cat "$AS_LOG")" "sidecar held"
assert_rc "sidecar publication failure rolls the published environment back" "$(
    cmp -s "$AS/.env" "$AS/env.expected"
    echo $?
)" 0
assert_rc "sidecar publication failure keeps the live sidecar" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
assert_eq "sidecar publication failure cleans all staging artifacts" "$(as_staged)" ""
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"

: >"$AS_LOG"
AS_PUBLISH_FAIL="sidecar-and-rollback"
out="$(as_apply -y)"
rollback_fail_rc=$?
unset AS_PUBLISH_FAIL
rollback_previous=$(find "$AS" -maxdepth 1 -name '.env.new.*.previous' -print)
assert_rc "a sidecar failure with a failed environment rollback aborts apply" "$rollback_fail_rc" 1
assert_contains "failed rollback reports the retained recovery path" "$out" ".previous"
assert_eq "failed rollback retains one environment recovery file" \
    "$(printf '%s\n' "$rollback_previous" | grep -c '.env.new.*.previous')" 1
assert_rc "failed rollback still keeps the live sidecar" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
rm -f "$rollback_previous"
cp "$AS/live.expected" "$AS_SECRET"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"

as_start_confirm
assert_contains "config revision race reaches a staged sidecar" "$(as_staged)" ".tari-wallet-secret"
printf '\n' >>"$AS/config.json"
as_finish_confirm "$AS_SUFFIX"
assert_rc "apply rejects a config revision changed after rendering" "$AS_RC" 1
assert_rc "config revision rejection keeps the live environment" "$(
    cmp -s "$AS/.env" "$AS/env.expected"
    echo $?
)" 0
assert_rc "config revision rejection keeps the live sidecar" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
assert_eq "config revision rejection cleans all staging artifacts" "$(as_staged)" ""
cp "$AS/config.expected" "$AS/config.json"
cp "$AS/env.expected" "$AS/.env"
cp "$AS/live.expected" "$AS_SECRET"

as_start_confirm
assert_contains "environment revision race reaches a staged sidecar" "$(as_staged)" ".tari-wallet-secret"
printf 'EXTERNAL_REVISION_MARKER=true\n' >>"$AS/.env"
as_finish_confirm "$AS_SUFFIX"
assert_rc "apply rejects a live environment revision changed after rendering" "$AS_RC" 1
assert_eq "environment revision rejection preserves the external writer" \
    "$(grep -cx 'EXTERNAL_REVISION_MARKER=true' "$AS/.env")" 1
assert_rc "environment revision rejection keeps the live sidecar" "$(
    cmp -s "$AS_SECRET" "$AS/live.expected"
    echo $?
)" 0
assert_eq "environment revision rejection cleans all staging artifacts" "$(as_staged)" ""
cp "$AS/env.expected" "$AS/.env"
cp "$AS/config.expected" "$AS/config.json"
cp "$AS/live.expected" "$AS_SECRET"

: >"$AS_LOG"
out="$(printf '%s\n' "$AS_SUFFIX" | as_apply)"
assert_rc "revision-valid typed apply succeeds" "$?" 0
assert_contains "environment publishes while the mutation lock is held" "$(cat "$AS_LOG")" "env held"
assert_contains "sidecar publishes while the mutation lock is held" "$(cat "$AS_LOG")" "sidecar held"
assert_not_contains "publication never renames either live file outside the mutation lock" "$(cat "$AS_LOG")" " free"
assert_eq "successful publication installs the confirmed Tari address" \
    "$(run_sourced "$AS" env_get_file "$AS/.env" TARI_WALLET_ADDRESS)" "$VALID_TARI_SINGLE"
assert_eq "published environment retains the live sidecar path" \
    "$(run_sourced "$AS" env_get_file "$AS/.env" TARI_WALLET_SECRET_FILE)" "$AS_SECRET"
printf 'MINOTARI_WALLET_VIEW_PRIVATE_KEY=%s\nMINOTARI_WALLET_SPEND_KEY=%s\nMINOTARI_WALLET_PASSWORD=%s\n' \
    "$(run_sourced "$AS" env_get_file "$AS/.env" TARI_VIEW_KEY)" \
    "$(run_sourced "$AS" env_get_file "$AS/.env" TARI_SPEND_PUBLIC_KEY)" \
    "$(run_sourced "$AS" env_get_file "$AS/.env" TARI_WALLET_PASSWORD)" >"$AS/sidecar.expected"
assert_rc "successful publication installs the rendered sidecar bytes" \
    "$(
        cmp -s "$AS_SECRET" "$AS/sidecar.expected"
        echo $?
    )" 0
assert_eq "successful publication removes all staging artifacts" "$(as_staged)" ""

: >"$AS_LOG"
out="$(as_apply -y)"
assert_rc "unchanged apply succeeds with a staged sidecar" "$?" 0
assert_contains "unchanged apply publishes the sidecar under the mutation lock" "$(cat "$AS_LOG")" "sidecar held"
assert_eq "unchanged apply removes all staging artifacts" "$(as_staged)" ""

: >"$AS_LOG"
: >"$AS/.env.apply-incomplete"
out="$(as_apply -y)"
assert_rc "retry apply succeeds with a staged sidecar" "$?" 0
assert_contains "retry apply publishes the sidecar under the mutation lock" "$(cat "$AS_LOG")" "sidecar held"
assert_eq "retry apply removes all staging artifacts" "$(as_staged)" ""

unset -f as_config as_apply as_staged as_start_confirm as_finish_confirm
