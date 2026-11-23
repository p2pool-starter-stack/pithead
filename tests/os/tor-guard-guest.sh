#!/usr/bin/env bash
set -Eeuo pipefail
stage=initialization
trap 'printf "Tor guard guest failed at %s (line %s, exit %s)\n" "$stage" "$LINENO" "$?" >&2' ERR
OFF_WINDOW=${OFF_WINDOW:-2400}
ON_WINDOW=${ON_WINDOW:-4500}
STUCK_WINDOW=${STUCK_WINDOW:-900}
DEFENSE_SEC=${DEFENSE_SEC:-1200}
cd /data/pithead
control=$(sed -n 's/^CONTROL_DIR=//p' .env)
data=$(sed -n 's/^TOR_DATA_DIR=//p' .env)
[ -d "$control" ] && [ -d "$data" ]
export TMPDIR="$control/work"
mkdir -p "$TMPDIR"
work=$(mktemp -d "$TMPDIR/tor-guard.XXXXXX")
cp config.json "$work/config.json"
mkdir "$work/orig-data"
cached_files() { find "$data" -maxdepth 1 -type f \( -name 'cached-*' -o -name state \); }
cached_files | while read -r f; do cp -a "$f" "$work/orig-data/"; done
image=$(docker inspect tor --format '{{.Config.Image}}')
net=$(docker inspect tor --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | cut -d' ' -f1)
prefix=$(docker inspect tor --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^NETWORK_PREFIX=//p')
[ -n "$image" ] && [ -n "$net" ] && [ -n "$prefix" ]
auth_ip=$prefix.200
guard_bad_ip=$prefix.201
good_guards=(202 203 204 205)
mid_ip=$prefix.206
exit_ip=$prefix.207
web_ip=$prefix.209
nodes=(tg-auth tg-guard-bad tg-guard-1 tg-guard-2 tg-guard-3 tg-guard-4 tg-mid tg-exit tg-web)
scrub() { sed -E 's/[1-9A-HJ-NP-Za-km-z]{85,}/[redacted-address]/g'; }
down_net() {
    docker rm -f "${nodes[@]}" >/dev/null 2>&1 || true
    docker volume rm -f tg-auth >/dev/null 2>&1 || true
}
restore_data() {
    cached_files | while read -r f; do rm -f "$f"; done
    find "$work/orig-data" -type f | while read -r f; do cp -a "$f" "$data/"; done
}
restore() {
    local rc=$? restored=0
    trap - EXIT ERR
    if [ "$rc" != 0 ]; then
        printf 'Guest diagnostics at failure:\n'
        for n in tg-guard-bad tg-auth; do
            printf -- '--- %s\n' "$n"
            docker logs --tail 25 "$n" 2>&1 | scrub | tail -c 3000 || true
        done
        docker logs --tail 25 tor 2>&1 | scrub | tail -c 3000 || true
    fi
    rm -f docker-compose.override.yml
    down_net
    docker compose stop tor >"$work/restore-stop.log" 2>&1 || restored=1
    restore_data || restored=1
    cp "$work/config.json" config.json || restored=1
    docker compose start tor >"$work/restore-start.log" 2>&1 || restored=1
    ./pithead apply -y >"$work/restore.log" 2>&1 || restored=1
    printf 'Guest restoration exit: %s; original exit: %s\n' "$restored" "$rc"
    if [ "$rc" = 0 ] && [ "$restored" != 0 ]; then rc=1; fi
    exit "$rc"
}
trap restore EXIT
configure() {
    jq --argjson enabled "$1" '.tor.auto_heal=$enabled | .notifications.tor=false' config.json >"$work/next-config"
    cp "$work/next-config" config.json
    ./pithead apply -y >"$work/apply.log" 2>&1
}
node_run() {
    local name=$1 ip=$2 torrc=$3
    docker run -d --name "$name" --network "$net" --ip "$ip" --user tor -e "TORRC=$torrc" \
        --entrypoint sh "$image" -c 'printf "%s\n" "$TORRC" >/var/lib/tor/torrc && exec tor -f /var/lib/tor/torrc' >/dev/null
}
relay_torrc() {
    printf '%s\n' "TestingTorNetwork 1" "DataDirectory /var/lib/tor" "Nickname $1" "Address $2" \
        "ORPort 9001" "DirPort 9030" "SocksPort 0" "Log notice stdout" \
        "HeartbeatPeriod 1 minute" "$dirauth" "${@:3}"
}
build_authority() {
    local out
    docker volume create tg-auth >/dev/null
    out=$(docker run --rm --user root -v tg-auth:/var/lib/tor --entrypoint sh "$image" -c "
        set -ex
        command -v tor-gencert
        cd /var/lib/tor
        mkdir -p keys
        printf '\n' | tor-gencert --create-identity-key -m 12 --passphrase-fd 0 \
            -i keys/authority_identity_key -s keys/authority_signing_key -c keys/authority_certificate \
            -a $auth_ip:9030
        v3id=\$(awk '/^fingerprint /{print \$2}' keys/authority_certificate)
        printf 'TestingTorNetwork 1\nDataDirectory /var/lib/tor\nNickname tgauth\nAddress $auth_ip\nORPort 9001\nDirPort 9030\nSocksPort 0\nDirAuthority tgauth orport=9001 no-v2 v3ident=%s $auth_ip:9030 0000000000000000000000000000000000000000\n' \"\$v3id\" >probe-torrc
        chown -R tor:tor /var/lib/tor
        chmod 700 /var/lib/tor
        su -s /bin/sh tor -c 'cd /var/lib/tor && tor -f probe-torrc --list-fingerprint' >&2
        printf 'V3 %s\n' \"\$(awk '/^fingerprint /{print \$2}' keys/authority_certificate)\"
        printf 'FP %s\n' \"\$(cut -d' ' -f2- fingerprint | tr -d ' ')\"
        chown -R tor:tor /var/lib/tor
        chmod 700 /var/lib/tor
    " 2>"$work/auth.err") || {
        tail -n 30 "$work/auth.err" >&2
        return 1
    }
    v3=$(printf '%s\n' "$out" | sed -n 's/^V3 //p')
    fp=$(printf '%s\n' "$out" | sed -n 's/^FP //p')
    [[ "$v3" =~ ^[0-9A-Fa-f]{40}$ && "$fp" =~ ^[0-9A-Fa-f]{40}$ ]]
    dirauth="DirAuthority tgauth orport=9001 no-v2 v3ident=$v3 $auth_ip:9030 $fp"
}
start_authority() {
    local torrc
    torrc=$(relay_torrc tgauth "$auth_ip" "AuthoritativeDirectory 1" "V3AuthoritativeDirectory 1" \
        "ContactInfo tg@example.invalid" "V3AuthVotingInterval 20 seconds" "V3AuthVoteDelay 4 seconds" \
        "V3AuthDistDelay 4 seconds" "TestingV3AuthInitialVotingInterval 20 seconds" \
        "TestingV3AuthInitialVoteDelay 4 seconds" "TestingV3AuthInitialDistDelay 4 seconds" \
        "TestingDirAuthVoteGuard tgbad,tgg1,tgg2,tgg3,tgg4" "TestingDirAuthVoteGuardIsStrict 1" \
        "TestingDirAuthVoteExit tgexit" "TestingDirAuthVoteExitIsStrict 1" "TestingDirAuthVoteHSDir *")
    docker run -d --name tg-auth --network "$net" --ip "$auth_ip" --user tor -v tg-auth:/var/lib/tor \
        -e "TORRC=$torrc" --entrypoint sh "$image" -c 'printf "%s\n" "$TORRC" >/var/lib/tor/torrc && exec tor -f /var/lib/tor/torrc' >/dev/null
}
start_fixture() {
    local torrc
    build_authority
    start_authority
    node_run tg-mid "$mid_ip" "$(relay_torrc tgmid "$mid_ip")"
    node_run tg-exit "$exit_ip" "$(relay_torrc tgexit "$exit_ip" "ExitRelay 1" "ExitPolicyRejectPrivate 0" \
        "ExitPolicy accept $web_ip:8080,accept *:80,accept *:443,reject *:*")"
    docker run -d --name tg-web --network "$net" --ip "$web_ip" --user tor --entrypoint sh "$image" -c \
        'mkdir -p /tmp/www && echo ok >/tmp/www/index.html && exec busybox httpd -f -p 8080 -h /tmp/www' >/dev/null
    torrc=$(relay_torrc tgbad "$guard_bad_ip" "DoSCircuitCreationEnabled 1" "DoSCircuitCreationMinConnections 1" \
        "DoSCircuitCreationRate 1" "DoSCircuitCreationBurst 3" "DoSCircuitCreationDefenseType 2" \
        "DoSCircuitCreationDefenseTimePeriod $DEFENSE_SEC seconds")
    node_run tg-guard-bad "$guard_bad_ip" "$torrc"
}
start_good_guards() {
    local i=1 octet
    for octet in "${good_guards[@]}"; do
        node_run "tg-guard-$i" "$prefix.$octet" "$(relay_torrc "tgg$i" "$prefix.$octet")"
        i=$((i + 1))
    done
}
write_override() {
    docker run --rm --entrypoint cat "$image" /etc/tor/torrc.template >"$work/torrc.private"
    printf '\nTestingTorNetwork 1\n%s\n' "$dirauth" >>"$work/torrc.private"
    cat >docker-compose.override.yml <<YAML
services:
  tor:
    environment:
      - TORRC_TEMPLATE=/etc/tor/torrc.private
    volumes:
      - $work/torrc.private:/etc/tor/torrc.private:ro
  dashboard:
    environment:
      - TOR_HEAL_PROBE_URL=http://$web_ip:8080/
      - TOR_HEAL_SECOND_PROBE_URL=http://$web_ip:8080/second
YAML
}
ctl() {
    docker exec tor sh -c 'cookie=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie); printf "AUTHENTICATE %s\r\n%s\r\nQUIT\r\n" "$cookie" "$1" | nc -w 3 127.0.0.1 9051' sh "$1" 2>/dev/null | tr -d '\r'
}
tor_state() { ctl 'GETINFO status/bootstrap-phase status/circuit-established entry-guards'; }
is_stuck() {
    local s
    s=$(tor_state)
    printf '%s\n' "$s" | grep -Eq '^250-status/bootstrap-phase=.* PROGRESS=95 TAG=circuit_create( |$)' &&
        printf '%s\n' "$s" | grep -qx '250-status/circuit-established=0' &&
        printf '%s\n' "$s" | grep -Eq '~tgbad up'
}
is_established() { tor_state | grep -qx '250-status/circuit-established=1'; }
egress_ok() {
    docker exec dashboard python3 -I -c '
import os
import requests
proxy = os.environ["TOR_SOCKS_PROXY"]
r = requests.get(os.environ["TOR_HEAL_PROBE_URL"], proxies={"http": proxy, "https": proxy}, timeout=20)
raise SystemExit(0 if r.status_code < 600 else 1)' >/dev/null 2>&1
}
channel_open() {
    docker exec tg-guard-bad netstat -tn 2>/dev/null | grep -E "ESTABLISHED" | grep -q "$prefix.25:"
}
dos_rejected() {
    docker logs tg-guard-bad 2>&1 | sed -n 's/.*DoS mitigation since startup: .* \([0-9][0-9]*\) circuits rejected.*/\1/p' | tail -n 1
}
guard_nicks() { tor_state | sed -n 's/^[^~ ]*~\(tg[a-z0-9]*\) \(up\|down\).*/\1:\2/p' | tr '\n' ' '; }
dropguards_audit() {
    find "$control/results" -maxdepth 1 -name '*.json' -type f -exec \
        jq -e --argjson started "$1" 'select(.action == "tor-dropguards" and .status == "applied" and .ts >= $started)' {} \; 2>/dev/null | grep -c tor-dropguards || true
}
bring_up_leg() {
    stage=$1-teardown
    down_net
    rm -f docker-compose.override.yml
    docker compose stop tor >"$work/leg-stop.log" 2>&1
    restore_data
    stage=$1-configure
    configure "$2"
    stage=$1-fixture
    docker compose stop tor >"$work/leg-stop2.log" 2>&1
    cached_files | while read -r f; do rm -f "$f"; done
    start_fixture
    write_override
    sleep 60
    docker compose up -d --no-deps --force-recreate tor dashboard >"$work/leg-up.log" 2>&1
    tor_started=$(docker inspect tor --format '{{.State.StartedAt}}')
    leg_start=$(date +%s)
}
wait_stuck() {
    local deadline=$((SECONDS + STUCK_WINDOW)) hits=0
    stage=$1-stuck
    while [ "$SECONDS" -lt "$deadline" ]; do
        if is_stuck; then
            hits=$((hits + 1))
            [ "$hits" -ge 3 ] && break
        else
            hits=0
        fi
        sleep 20
    done
    if [ "$hits" -lt 3 ]; then
        printf 'RECORD %s: fault not reproduced: guards=%s\n' "$1" "$(guard_nicks)" >&2
        tor_state | head -n 12 >&2 || true
        return 1
    fi
    channel_open || {
        printf 'RECORD %s: the guard channel is not open while stuck\n' "$1" >&2
        return 1
    }
    stuck_at=$(date +%s)
    printf 'RECORD %s: stuck at bootstrap 95 after %ss with guard channel open, guards=%s\n' "$1" "$((stuck_at - leg_start))" "$(guard_nicks)"
}
rejected_total=0
note_rejections() {
    local n
    n=$(dos_rejected)
    n=${n:-0}
    printf 'RECORD %s: guard DoS counter circuits rejected=%s\n' "$1" "$n"
    [ "$n" -gt 0 ] || {
        printf 'the guard never logged a refused circuit create, so the stall is not the DoS defence\n' >&2
        return 1
    }
    rejected_total=$((rejected_total + n))
}
stage=off-leg
bring_up_leg off false
wait_stuck off
start_good_guards
note_rejections off
stage=off-observe
deadline=$((stuck_at + OFF_WINDOW))
off_recovered=none
while [ "$(date +%s)" -lt "$deadline" ]; do
    if is_established && egress_ok; then
        off_recovered=$(($(date +%s) - stuck_at))
        break
    fi
    sleep 30
done
[ "$(docker inspect tor --format '{{.State.StartedAt}}')" = "$tor_started" ]
[ "$(dropguards_audit "$leg_start")" = 0 ]
printf 'RECORD off: untouched Tor recovery after stuck: %s (window %ss, defence period %ss)\n' "$off_recovered" "$OFF_WINDOW" "$DEFENSE_SEC"
echo 'PASS: refused circuit creates on an open guard channel stall an untouched Tor (#4342)'
stage=on-leg
bring_up_leg on true
wait_stuck on
start_good_guards
note_rejections on
guards_before=$(guard_nicks)
stage=on-observe
deadline=$((stuck_at + ON_WINDOW))
on_recovered=none
while [ "$(date +%s)" -lt "$deadline" ]; do
    if is_established && egress_ok; then
        on_recovered=$(($(date +%s) - stuck_at))
        break
    fi
    sleep 30
done
guards_after=$(guard_nicks)
rotations=$(dropguards_audit "$leg_start")
printf 'RECORD on: rotations audited=%s recovery after stuck=%s guards before=[%s] after=[%s]\n' "$rotations" "$on_recovered" "$guards_before" "$guards_after"
[ "$rotations" -ge 1 ]
[ "$on_recovered" != none ]
[ "$(docker inspect tor --format '{{.State.StartedAt}}')" = "$tor_started" ]
echo 'PASS: guard rotation cures refused circuit creates without a Tor restart (#4342)'
printf 'RECORD verdict: rotation alone cures the fault; untouched Tor recovery %s; DoS refusals logged %s\n' "$off_recovered" "$rejected_total"
