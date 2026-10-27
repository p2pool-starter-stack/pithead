# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"

manual_qa_oracle() {
    local SANDBOX="$SANDBOX/manual-qa" C CTRL_LOG
    local id edit expected change out rc row count=0
    local cases="$ROOT/docs/dev/manual-qa/broken-configs.tsv"
    local guide="$ROOT/docs/dev/manual-qa/sample-configs.md"
    build_control_sandbox
    seed_control_env
    control_config mini
    cp "$ROOT/VERSION" "$C/VERSION"
    cp "$C/config.json" "$C/valid.json"
    cp "$C/.env" "$C/env.before"
    out=$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run 2>&1)
    assert_rc "manual-QA baseline passes real dry-run validation" "$?" 0
    while IFS=$'\t' read -r id edit expected change; do
        [ "$id" != id ] || continue
        count=$((count + 1))
        row=$(grep -F "| \`$id\` | " "$guide")
        assert_rc "$id has its own guide row" "$?" 0
        assert_eq "$id guide row matches the replay case" "$row" "| \`$id\` | $change | \`$expected\` |"
        jq -r --arg subaddress "$VALID_SUBADDR" "$edit" "$C/valid.json" >"$C/config.json"
        rc=$?
        assert_rc "$id mutation produces the candidate" "$rc" 0
        [ "$rc" -eq 0 ] || return 1
        cp "$C/config.json" "$C/config.before"
        : >"$CTRL_LOG"
        out=$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run 2>&1)
        rc=$?
        assert_rc "$id dry run refuses the broken config" "$rc" 1
        assert_contains "$id dry run reports the guide's refusal" "$out" "$expected"
        cmp -s "$C/config.json" "$C/config.before"
        assert_rc "$id dry run preserves candidate bytes" "$?" 0
        cmp -s "$C/.env" "$C/env.before"
        assert_rc "$id dry run preserves rendered environment bytes" "$?" 0
        assert_eq "$id dry run makes only disposable password-hash calls" \
            "$(grep -vE '^\[docker\] run --rm -i --log-driver none [^ ]+ caddy hash-password$' "$CTRL_LOG")" ""
    done <"$cases"
    assert_eq "every guide case is replayed exactly once" \
        "$(tail -n +2 "$cases" | cut -f1 | sort)" \
        "$(awk -F '`' '/^## Broken configs$/ {section=1; next} section && /^## / {exit} section && /^\| `/ {print $2}' "$guide" | sort -u)"
    assert_eq "the full broken-config battery runs" "$count" 17
    out=$(awk '/^## New to mining\?/ {section=1; next} section && /^## / {exit} section {print}' "$ROOT/docs/workers.md")
    assert_contains "RigForge quick-start clones the owner's release pin" "$out" \
        'git clone --branch v1.18.0 https://github.com/p2pool-starter-stack/rigforge.git'
    assert_not_contains "RigForge quick-start never follows the moving default branch" "$out" \
        'git clone https://github.com/p2pool-starter-stack/rigforge.git'
}

manual_qa_oracle
