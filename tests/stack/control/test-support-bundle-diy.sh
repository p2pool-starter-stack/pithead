# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
: "${SANDBOX:?}"

DB="$SANDBOX/diybundle"
mkdir -p "$DB/bin" "$DB/work"
DB_ADDR="44nep4y8xiQPH96nSQgkChrvUXLrLb73HK5sSGa6hVt3thisdUwb9BtFKdw9iQ89GE7yWW8xvRqG6HZrAro79hPDvYSrqCG"
DB_ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"

cat >"$DB/bin/docker" <<'STUB'
#!/usr/bin/env bash
[ -z "${DB_ENGINE_DOWN:-}" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$*" in
"compose ps --all --format {{.Name}}") printf 'stack-alpha-1\nstack-beta-1\n' ;;
"compose ps --all") printf 'NAME STATUS\nstack-alpha-1 running\nstack-beta-1 exited\n' ;;
logs*)
    echo "$*" >>"$DB_DOCKER_LOG"
    name="${*: -1}"
    case "$name" in
    stack-alpha-1)
        echo "alpha: window marker --rpc-login rpcuser:dockpassvalue --wallet $DB_ADDR"
        echo "alpha: served $DB_ONION" >&2
        for i in $(seq 1 300); do echo "alpha: bulk-$i"; done
        ;;
    stack-beta-1) echo "beta: stopped container marker" ;;
    esac
    ;;
esac
STUB
cat >"$DB/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
*"-n 1"*)
    if [ -n "${DB_JOURNAL_DENIED:-}" ]; then
        echo "No journal files were opened due to insufficient permissions." >&2
    fi
    exit 0
    ;;
*"--disk-usage"*) echo "Archived and active journals take up 8.0M in the file system." ;;
*"-o short-unix"*) echo "$(($(date +%s) - 360000)).000000 host x: oldest" ;;
*"-u pithead-egress.service"*) echo "Nov 15 10:30:00 host egress: journal marker --rpc-login egressuser:egresspassvalue" ;;
esac
STUB
cat >"$DB/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
*list-unit-files*)
    printf 'pithead-egress.service enabled enabled\n'
    printf 'pithead-egress.timer enabled enabled\n'
    ;;
esac
exit 0
STUB
chmod +x "$DB/bin/"*
printf '{"dashboard":{"auth":{"password":"dashseedsecret"}}}\n' >"$DB/work/config.json"
printf 'PROXY_STRATUM_PASSWORD=envseedsecret\nSTRATUM_PORT=3333\n' >"$DB/work/.env"

db_iso() { date -u -d "@$(($(date +%s) + $1))" +%Y-%m-%dT%H:%M:%SZ; }
db_run() {
    (
        cd "$DB/work" || exit
        rm -f support-bundle-*.zip
        export PATH="$DB/bin:$PATH" PITHEAD_APPLIANCE=0 DB_ADDR DB_ONION DB_DOCKER_LOG="$DB/docker.log"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        doctor_json() {
            echo 'doctor report' >&2
            echo '{"checks":[],"summary":{}}'
        }
        render_masked_config() {
            mkdir -p "$1/masked"
            printf '{"dashboard":{"auth":{"password":{"__secret__":true}}}}\n' >"$1/masked/config.json"
        }
        stack_support_bundle "$@"
        echo "RC:$?"
    ) 2>&1
}
db_unzip() {
    rm -rf "$2"
    mkdir -p "$2"
    python3 -I -m zipfile -e "$1" "$2" >/dev/null
}
db_man() { jq -r "$2" "$1/bundle/manifest.json"; }
db_zips() { find "$DB/work" -maxdepth 1 -name 'support-bundle-*.zip'; }

echo "== support-bundle (DIY): a windowed zip with container logs, DIY units and a manifest (#4130) =="
rm -f "$DB/docker.log"
out="$(db_run --since "$(db_iso -7200)" --until "$(db_iso -600)")"
assert_contains "the verb succeeds" "$out" "RC:0"
zip="$(db_zips)"
assert_eq "one zip is written in the current directory" "$(printf '%s\n' "$zip" | grep -c .)" "1"
assert_eq "no tarball is written" "$(find "$DB/work" -maxdepth 1 -name '*.tar.gz' | wc -l | tr -d ' ')" "0"
assert_eq "the zip is mode 600" "$(stat -c '%a' "$zip")" "600"
assert_eq "the stock zip reader accepts it" "$(python3 -I -m zipfile -t "$zip" >/dev/null 2>&1 && echo ok)" "ok"
db_unzip "$zip" "$DB/x1"
assert_contains "a running container's log is collected" "$(cat "$DB/x1/bundle/containers/stack-alpha-1.log")" "alpha: window marker"
assert_contains "a stopped container's log is collected" "$(cat "$DB/x1/bundle/containers/stack-beta-1.log")" "beta: stopped container marker"
assert_contains "a container's stderr is collected" "$(cat "$DB/x1/bundle/containers/stack-alpha-1.log")" "alpha: served"
assert_eq "the 200-line limit is gone" "$([ "$(wc -l <"$DB/x1/bundle/containers/stack-alpha-1.log")" -gt 250 ] && echo yes)" "yes"
win_since="$(db_man "$DB/x1" '.window.requested.since')"
win_until="$(db_man "$DB/x1" '.window.requested.until')"
assert_contains "docker logs is asked for the window start" "$(cat "$DB/docker.log")" "--since $win_since"
assert_contains "docker logs is asked for the window end, inclusive of its last second" \
    "$(cat "$DB/docker.log")" "--until $(date -u -d "$win_until + 1 second" +%Y-%m-%dT%H:%M:%SZ)"
assert_contains "the egress unit's journal is collected" "$(cat "$DB/x1/bundle/logs/pithead-egress.service.log")" "egress: journal marker"
for unit in pithead-egress.timer pithead-lan-guard.service pithead-lan-hold.service pithead-lan.timer; do
    assert_eq "$unit has an entry in the manifest" "$(db_man "$DB/x1" "[.files[].path] | index(\"logs/$unit.log\") != null")" "true"
done
assert_eq "an installed DIY unit with nothing in the window is empty" \
    "$(db_man "$DB/x1" '.files[] | select(.path == "logs/pithead-egress.timer.log") | .state')" "empty"
assert_eq "a DIY unit that is not installed is missing" \
    "$(db_man "$DB/x1" '.files[] | select(.path == "logs/pithead-lan.timer.log") | .state')" "missing"
assert_eq "appliance-only sources are not collected" \
    "$(db_man "$DB/x1" '[.files[].path] | map(select(startswith("journal/") or . == "rauc.txt")) | length')" "0"
assert_eq "the manifest has the same top-level fields as the appliance zip" \
    "$(db_man "$DB/x1" '[has("manifest_version","pithead_version","collected_at","window","journald","size_policy","files","failures")] | all')" "true"
assert_eq "a clean collection records no failed step" "$(db_man "$DB/x1" '.failures | length')" "0"
assert_eq "a container file has an ok state and a window in the manifest" \
    "$(db_man "$DB/x1" '.files[] | select(.path == "containers/stack-alpha-1.log") | (.state == "ok") and (.window.until != null)')" "true"
assert_eq "doctor, the masked config, the redacted env and the container list stay in the bundle" \
    "$(for f in doctor.json doctor.txt config.masked.json env.redacted compose-ps.txt; do [ -s "$DB/x1/bundle/$f" ] && printf y; done)" "yyyyy"
assert_contains "the env keeps its structure" "$(cat "$DB/x1/bundle/env.redacted")" "STRATUM_PORT=3333"

echo "== support-bundle (DIY): no seeded secret reaches the zip =="
for secret in dockpassvalue egresspassvalue envseedsecret "$DB_ADDR" "$DB_ONION"; do
    assert_not_contains "the seeded value ${secret:0:12} is ABSENT from the whole zip" "$(grep -rF "$secret" "$DB/x1" || true)" "$secret"
done
assert_contains "the redactor fired on a container log" "$(cat "$DB/x1/bundle/containers/stack-alpha-1.log")" "[redacted"
assert_contains "the redactor fired on a journal file" "$(cat "$DB/x1/bundle/logs/pithead-egress.service.log")" "[redacted]"

echo "== support-bundle (DIY): a stopped engine or an unreadable journal does not fail the bundle =="
out="$(DB_ENGINE_DOWN=1 DB_JOURNAL_DENIED=1 db_run)"
assert_contains "the verb still succeeds" "$out" "RC:0"
db_unzip "$(db_zips)" "$DB/x2"
assert_contains "the engine failure is in the manifest" "$(db_man "$DB/x2" '[.failures[] | select(.step == "containers") | .reason] | join(" ")')" "not reachable"
assert_contains "the journal failure is in the manifest" "$(db_man "$DB/x2" '[.failures[] | select(.step == "journal") | .reason] | join(" ")')" "not readable"
assert_eq "no unit file claims an empty journal when it could not be read" \
    "$(db_man "$DB/x2" '[.files[].path] | map(select(startswith("logs/"))) | length')" "0"
assert_contains "the container list says the engine was not reachable" "$(cat "$DB/x2/bundle/compose-ps.txt")" "not reachable"

echo "== support-bundle (DIY): the window is validated like recovery-bundle =="
assert_contains "a start after the end is refused" "$(db_run --since "$(db_iso -60)" --until "$(db_iso -3600)")" "after end time"
assert_eq "a refused window writes nothing" "$(db_zips | wc -l | tr -d ' ')" "0"
assert_contains "a future end is refused" "$(db_run --until "$(db_iso 7200)")" "in the future"
assert_contains "an unparsable time is refused" "$(db_run --since yesterday)" "RFC 3339"
assert_contains "an unknown option is refused with usage" "$(db_run --bogus x)" "Usage: pithead support-bundle"
assert_contains "--hours still works" "$(db_run --hours 5)" "RC:0"
