# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# #1843: a rig install staged onto the ESP must already carry the control token the stick's
# wizard minted before the card (#1836) — that card is the only place the token is ever shown.
# A staged file with no well-formed token was never confirmed on one, so the landing leg in
# firstboot_wizard (lib/pithead/12-firstboot-wizard.sh) refuses it rather than landing it and
# minting a token nobody saw.

echo "== unit: a staged rig file with no token is refused, never landed and minted unseen (#1843) =="
mk_tmpdir RTLB
mk_tmpdir RTLESP
mkdir -p "$RTLB/rigforge"
export PITHEAD_PRESEED_DIR="$RTLESP" PITHEAD_RIGFORGE_DIR="$RTLB/rigforge"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$RTLESP/pithead-rig.json"
out=$(PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$RTLB" firstboot_wizard 2>&1) || true
assert_contains "the missing token is named" "$out" "unusable"
[ -f "$RTLB/rig.json" ] && bad "a tokenless staged file lands anyway" "landed" || ok "a tokenless staged file is never landed"
[ -f "$RTLB/machine-role" ] && bad "a tokenless staged file marks a role anyway" "marked" || ok "no role is marked"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","access_token":"dcfda835679ae98638633f189d9e5979"}' >"$RTLESP/pithead-rig.json"
run_sourced "$RTLB" firstboot_wizard >/dev/null 2>&1
assert_eq "a well-formed token lands and rides through unminted" \
    "$(jq -r '.access_token' "$RTLB/rig.json")" "dcfda835679ae98638633f189d9e5979"
unset PITHEAD_PRESEED_DIR PITHEAD_RIGFORGE_DIR
rm -rf "$RTLB" "$RTLESP"
unset RTLB RTLESP out
