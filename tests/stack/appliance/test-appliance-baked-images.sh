# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== unit: load_baked_images — the wizard loads only its own archive, provisioning loads the rest (#978) =="
mk_tmpdir BKI
mkdir -p "$BKI/images" "$BKI/bin" "$BKI/data"
printf 'dashboard-archive' >"$BKI/images/dashboard.tar.gz"
printf 'tor-archive' >"$BKI/images/tor.tar.gz"
printf 'caddy-archive' >"$BKI/images/caddy.tar.gz"
cat >"$BKI/bin/podman" <<'PODMAN'
#!/usr/bin/env bash
echo "[podman] $*" >>"${PODMAN_LOG:-/dev/null}"
case "$1" in
image) exit 1 ;;
esac
PODMAN
chmod +x "$BKI/bin/podman"
export PODMAN_LOG="$BKI/podman.log" PITHEAD_IMAGES_DIR="$BKI/images"
bki_load() { PITHEAD_ENGINE=podman PATH="$BKI/bin:$PATH" run_sourced "$BKI" load_baked_images; }
PITHEAD_LOAD_ONLY="dashboard caddy" bki_load >/dev/null 2>&1
assert_eq "PITHEAD_LOAD_ONLY loads exactly the named archives" "$(grep -c 'load -i' "$PODMAN_LOG")" "2"
assert_contains "the first named archive is loaded" "$(cat "$PODMAN_LOG")" "dashboard.tar.gz"
assert_contains "the second named archive is loaded" "$(cat "$PODMAN_LOG")" "caddy.tar.gz"
[ -s "$BKI/data/.loaded-dashboard.tar.gz.sha" ] && [ -s "$BKI/data/.loaded-caddy.tar.gz.sha" ] && [ ! -e "$BKI/data/.loaded-tor.tar.gz.sha" ] &&
    ok "only the named archives are recorded as loaded" || bad "only the named archives are recorded as loaded" "records: $(ls -A "$BKI/data")"
: >"$PODMAN_LOG"
bki_load >/dev/null 2>&1
assert_contains "an unfiltered load reaches the archives the wizard skipped" "$(cat "$PODMAN_LOG")" "tor.tar.gz"
assert_eq "an unfiltered load does not reload the archives already recorded" "$(grep -c 'load -i' "$PODMAN_LOG")" "1"
unset PODMAN_LOG PITHEAD_IMAGES_DIR
unset -f bki_load
rm -rf "$BKI"
unset BKI

echo "== unit: setup loads every baked archive before it provisions Tor on an appliance (#978) =="
mk_tmpdir SLB
slb_probe() {
    mutation_lock_acquire() { :; }
    load_baked_images() { echo load-baked-images >>"$SLB/log"; }
    check_prerequisites() {
        echo check-prerequisites >>"$SLB/log"
        return 0
    }
    ensure_config_exists() { exit 0; }
    setup_confirmed
}
for appliance in 1 0; do
    : >"$SLB/log"
    PITHEAD_APPLIANCE=$appliance run_sourced "$SLB" slb_probe >/dev/null 2>&1 || true
    if [ "$appliance" = 1 ]; then
        assert_eq "an appliance loads its archives, then checks prerequisites" "$(tr '\n' ' ' <"$SLB/log")" "load-baked-images check-prerequisites "
    else
        assert_eq "a DIY install loads nothing" "$(tr '\n' ' ' <"$SLB/log")" "check-prerequisites "
    fi
done
rm -rf "$SLB"
unset SLB appliance
unset -f slb_probe
