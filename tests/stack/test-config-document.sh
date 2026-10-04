# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"

echo "== raw config document refusals =="
build_val_sandbox
for raw in \
    '{"monero":{},"monero":{}}' \
    '{"dashboard":{"auth":{"password":"first","password":"last"}}}' \
    '{"dashboard":{"auth":{"password":"PASTE_secret"}}}' \
    '{"telegram":{"bot_token":"YOUR_token"}}' \
    '{"telegram":{"chat_id":"paste_chat"}}' \
    '{"monero":{"node_username":"YOUR_user"}}' \
    '{"monero":{"node_password":"PASTE_secret"}}' \
    '{"workers":{"list":[{"token":"YOUR_token"}]}}'; do
    for verb in preview apply setup up; do
        seed_env
        case "$verb" in
        preview) args=(apply --dry-run) ;;
        apply) args=(apply -y) ;;
        setup) args=(setup --skip-deps --skip-optimize) && rm "$V/.env" ;;
        up) args=(up) ;;
        esac
        printf '%s\n' "$raw" >"$V/config.json"
        cp "$V/config.json" "$V/config.before"
        [ ! -f "$V/.env" ] || cp "$V/.env" "$V/env.before"
        out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead "${args[@]}" 2>&1)"
        assert_rc "$verb refuses $raw" "$?" 1
        case "$raw" in
        *'first'*) expected='dashboard.auth.password' ;;
        *'"monero":{},'*) expected='monero' ;;
        *'"password"'*) expected='dashboard.auth.password' ;;
        *'"bot_token"'*) expected='telegram.bot_token' ;;
        *'"chat_id"'*) expected='telegram.chat_id' ;;
        *'"node_username"'*) expected='monero.node_username' ;;
        *'"node_password"'*) expected='monero.node_password' ;;
        *) expected='workers.list[0].token' ;;
        esac
        assert_contains "$verb names the rejected path" "$out" "$expected"
        assert_not_contains "$verb never reveals the placeholder" "$out" 'PASTE_secret'
        cmp -s "$V/config.json" "$V/config.before"
        assert_rc "$verb leaves raw config unchanged" "$?" 0
        if [ "$verb" = setup ]; then
            assert_eq "setup wrote no env" "$(test -e "$V/.env" && echo written || echo absent)" absent
        else
            cmp -s "$V/.env" "$V/env.before"
            assert_rc "$verb leaves env unchanged" "$?" 0
        fi
    done
done

# The control writer can bypass HTTP: the host must inspect the raw request before jq staging.
build_control_sandbox
seed_control_env
control_config mini
out="$(cd "$C" && PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid control baseline provisions" "$?" 0
id=abcdefab-1234-4abc-8abc-123456789012
for raw in \
    '{"dashboard":{"auth":{"password":"first","password":"last"}}}' \
    '{"telegram":{"bot_token":"PASTE_secret"}}'; do
    printf '{"id":"%s","action":"preview","actor":"test","config":%s}\n' "$id" "$raw" >"$C/data/control/requests/$id.json"
    out="$(cd "$C" && PATH="$C/bin:$PATH" ./pithead control-run-pending 2>&1)"
    assert_rc "host drains invalid raw request" "$?" 0
    result="$(cat "$C/data/control/results/$id.json")"
    assert_contains "host refuses before staging" "$result" 'rejected'
    case "$raw" in
    *first*) assert_contains "host names duplicate path" "$result" 'dashboard.auth.password' ;;
    *) assert_contains "host names placeholder path" "$result" 'telegram.bot_token' ;;
    esac
    assert_eq "invalid request was never staged" "$(test -e "$C/data/control/staged/$id.json" && echo staged || echo absent)" absent
    rm -f "$C/data/control/results/$id.json"
done

# A staged intent is rechecked before policy/approval parsing can discard repeated keys.
mkdir -p "$C/data/control/staged"
printf '{"dashboard":{"auth":{"password":"first","password":"last"}}}\n' >"$C/data/control/staged/$id.json"
out="$(run_sourced "$C" control_approval_gate "$C/data/control/staged/$id.json" APPLY "$id" test null "$C/data/control" 2>&1)"
assert_rc "commit gate rejects duplicated staged key" "$?" 1
assert_contains "commit gate names duplicated staged key" "$out" 'dashboard.auth.password'
unset raw verb args expected id result
