#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== checklist samples and refusal contracts =="
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"
build_val_sandbox
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml" || exit 1
cases="$SANDBOX/checklist"
mkdir -p "$cases"
python3 "$HERE/checklist-cases.py" "$ROOT/docs/dev/manual-qa/sample-configs.md" "$cases" "$VALID_PRIMARY" "$VALID_TARI" "$VALID_SUBADDR" || exit 1
for sample in "$cases"/sample-*.json; do
    seed_env
    cp "$sample" "$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply --dry-run 2>&1)"
    rc=$?
    assert_rc "checklist $(basename "$sample") validates" "$rc" 0
done
for candidate in "$cases"/broken-*.json; do
    label="$(basename "$candidate" .json)"
    for verb in dry-run apply; do
        [ "$label:$verb" != broken-16:apply ] || continue
        seed_env
        cp "$V/.env" "$cases/env.before"
        cp "$candidate" "$V/config.json"
        trace="$cases/docker.log"
        : >"$trace"
        args=(apply --dry-run)
        [ "$verb" != apply ] || args=(apply -y)
        out="$(cd "$V" && DOCKER_LOG="$trace" PATH="$V/bin:$PATH" ./pithead "${args[@]}" 2>&1)"
        assert_rc "$label $verb refuses" "$?" 1
        assert_contains "$label $verb operator message" "$out" "$(cat "${candidate%.json}.message")"
        cmp -s "$V/.env" "$cases/env.before"
        assert_rc "$label $verb leaves .env unchanged" "$?" 0
        if [ "$verb" = dry-run ]; then
            cmp -s "$V/config.json" "$candidate"
            assert_rc "$label $verb leaves candidate unchanged" "$?" 0
        fi
        if grep -Eq '(^| )up( |$)' "$trace"; then
            bad "$label $verb never starts compose" "compose up was invoked"
        else
            ok "$label $verb never starts compose"
        fi
    done
done
printf 'checklist: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
