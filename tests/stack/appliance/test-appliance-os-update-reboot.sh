# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# os-update's success message and its --reboot flag (#2382): a successful install used to print
# 'succeeded' and return, leaving a first-time operator to guess that a reboot was the next step
# at all — let alone that mining kept running the old version until then, or that the reboot only
# keeps the new one if the stack comes up healthy. This proves the CLI now says the state, the
# reboot contract, and the exact command, and that --reboot asks first unless -y is also given.
# Sourced by tests/stack/run.sh.
#
# This lives beside test-appliance-os-update-lock.sh rather than inside test-appliance-os-update.sh
# because that file sits at its recorded budget ceiling with zero headroom, and ceilings only go
# down (the same reason test-appliance-os-update-lock.sh sits beside it too).
#
# Re-derivations: none. $SANDBOX, $STACK and the assert_*/mk_tmpdir helpers come from lib.sh, which
# run.sh sources near its top. Every name here is scratch, assigned and cleaned up locally ($OUR,
# $rebooted, $out, $rc) — nothing shared with the other os-update files' own $OUSB/$OUB/$OSL, since
# all three run in the SAME shell and a clash would silently overwrite one file's fixture with
# another's.

: "${SANDBOX:?}"
: "${STACK:?}"

echo "== integration: a successful install says the state and the reboot step, not just 'succeeded' (#2382) =="
# 'succeeded' alone left an operator guessing (#2382 as filed): the bundle only wrote the spare
# slot, mining kept running the old version, and nothing said the reboot was the next step or what
# it would do. Run as a real subprocess, not sourced, so $0 in the message is genuinely
# './pithead' — the exact command an operator would type back.
mk_tmpdir OUR
mkdir -p "$OUR/bin"
cat >"$OUR/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info)
    [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT"
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$OUR/bin/rauc"
cp "$STACK" "$OUR/pithead"
chmod +x "$OUR/pithead"
touch "$OUR/bundle.raucb"
printf 'release\n' >"$OUR/variant-release"
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.9'\n" >"$OUR/info-versioned.txt"
rebooted="$OUR/.rebooted"
: >"$OUR/calls"
out=$(cd "$OUR" && PATH="$OUR/bin:$PATH" RAUC_LOG="$OUR/calls" \
    RAUC_INFO_OUT="$OUR/info-versioned.txt" PITHEAD_VARIANT_FILE="$OUR/variant-release" \
    PITHEAD_VERSION="1.0.0" \
    ./pithead os-update bundle.raucb --yes 2>&1)
rc=$?
assert_rc "-y with no --reboot installs cleanly" "$rc" "0"
assert_contains "the message names the version written and the version staying up" "$out" \
    "Installed 9.9.9 to the spare slot; this machine keeps running 1.0.0 until it reboots."
assert_contains "the message names the health-gated commit and the automatic fallback" "$out" \
    "it stays only if the stack comes up healthy, otherwise the next boot falls back"
assert_contains "the message names the exact reboot command" "$out" "systemctl reboot"
assert_contains "the message names --reboot as the one-step path" "$out" "os-update --reboot"
assert_eq "-y with no --reboot does not reboot" "$([ -f "$rebooted" ] || echo no)" "no"

echo "== integration: os-update --reboot, with -y, reboots without asking (#2382) =="
rm -f "$rebooted"
: >"$OUR/calls"
out=$(cd "$OUR" && PATH="$OUR/bin:$PATH" RAUC_LOG="$OUR/calls" \
    RAUC_INFO_OUT="$OUR/info-versioned.txt" PITHEAD_VARIANT_FILE="$OUR/variant-release" \
    PITHEAD_VERSION="1.0.0" PITHEAD_REBOOT_CMD="touch $rebooted" \
    ./pithead os-update bundle.raucb --yes --reboot </dev/null 2>&1)
rc=$?
assert_rc "--reboot with -y succeeds" "$rc" "0"
assert_eq "--reboot with -y reboots without a prompt" "$([ -f "$rebooted" ] && echo yes)" "yes"
assert_not_contains "no reboot prompt was printed under -y" "$out" "Reboot now?"

echo "== integration: os-update --reboot, without -y, asks first — an unanswered prompt does not reboot (#2382) =="
rm -f "$rebooted"
: >"$OUR/calls"
out=$(cd "$OUR" && PATH="$OUR/bin:$PATH" RAUC_LOG="$OUR/calls" \
    RAUC_INFO_OUT="$OUR/info-versioned.txt" PITHEAD_VARIANT_FILE="$OUR/variant-release" \
    PITHEAD_VERSION="1.0.0" PITHEAD_REBOOT_CMD="touch $rebooted" \
    ./pithead os-update bundle.raucb --reboot </dev/null 2>&1)
rc=$?
assert_rc "--reboot without -y, declined by EOF, exits clean" "$rc" "0"
assert_contains "the reboot prompt was asked" "$out" "Reboot now?"
assert_eq "an unanswered reboot prompt does not reboot" "$([ -f "$rebooted" ] || echo no)" "no"
assert_contains "the operator is told how to finish it later" "$out" "os-update --reboot"

echo "== integration: os-update --reboot, without -y, confirmed 'y' — reboots (#2382) =="
rm -f "$rebooted"
: >"$OUR/calls"
out=$(cd "$OUR" && printf 'y\n' | PATH="$OUR/bin:$PATH" RAUC_LOG="$OUR/calls" \
    RAUC_INFO_OUT="$OUR/info-versioned.txt" PITHEAD_VARIANT_FILE="$OUR/variant-release" \
    PITHEAD_VERSION="1.0.0" PITHEAD_REBOOT_CMD="touch $rebooted" \
    ./pithead os-update bundle.raucb --reboot 2>&1)
rc=$?
assert_rc "--reboot without -y, confirmed -> succeeds" "$rc" "0"
assert_eq "a confirmed reboot prompt reboots" "$([ -f "$rebooted" ] && echo yes)" "yes"

rm -rf "$OUR"
unset rebooted out rc
