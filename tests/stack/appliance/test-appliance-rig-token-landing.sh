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
[ -f "$RTLESP/pithead-rig.json" ] && bad "the refused file sits on the ESP" "still there" || ok "the refused file is scrubbed off the ESP (it may hold a stratum password)"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","access_token":"dcfda835679ae98638633f189d9e5979"}' >"$RTLESP/pithead-rig.json"
run_sourced "$RTLB" firstboot_wizard >/dev/null 2>&1
assert_eq "a well-formed token lands and rides through unminted" \
    "$(jq -r '.access_token' "$RTLB/rig.json")" "dcfda835679ae98638633f189d9e5979"
unset PITHEAD_PRESEED_DIR PITHEAD_RIGFORGE_DIR
rm -rf "$RTLB" "$RTLESP"
unset RTLB RTLESP out
echo "== unit: firstboot_consume_rig — pool-kind keys, warnings and refusals (#4065) =="
mk_tmpdir PKSB
mkdir -p "$PKSB/bin" "$PKSB/spool"
printf '#!/bin/bash\nexit 0\n' >"$PKSB/bin/timeout"
chmod +x "$PKSB/bin/timeout"
printf '{"pool":"pool.example:5555","worker":"shed-3","tls":true,"tls_fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","paired":false}' >"$PKSB/spool/rig-request.json"
PATH="$PKSB/bin:$PATH" run_sourced "$PKSB" firstboot_consume_rig "$PKSB/spool" >/dev/null 2>&1
assert_rc "tls, pin and paired on a dialed port -> rc 0" "$?" "0"
assert_eq "tls lands verbatim" "$(jq -r '.tls' "$PKSB/rig.json")" "true"
assert_eq "the fingerprint lands verbatim" "$(jq -r '.tls_fingerprint' "$PKSB/rig.json")" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
assert_eq "paired lands verbatim" "$(jq -r '.paired' "$PKSB/rig.json")" "false"
assert_eq "no error.txt on an accepted request" "$(test -f "$PKSB/spool/error.txt" && echo yes || echo no)" "no"
rm -f "$PKSB/rig.json" "$PKSB/spool/rig-warning.txt"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$PKSB/spool/rig-request.json"
printf '#!/bin/bash\nexit 1\n' >"$PKSB/bin/timeout"
PATH="$PKSB/bin:$PATH" run_sourced "$PKSB" firstboot_consume_rig "$PKSB/spool" >/dev/null 2>&1
assert_rc "a dialed-down pool is accepted with a warning" "$?" "0"
assert_contains "the warning names the endpoint" "$(cat "$PKSB/spool/rig-warning.txt")" "10.0.0.5:3333"
assert_eq "a warned request is consumed" "$(test -f "$PKSB/spool/rig-request.json" && echo yes || echo no)" "no"
assert_eq "no error.txt beside a warning" "$(test -f "$PKSB/spool/error.txt" && echo yes || echo no)" "no"
rm -f "$PKSB/spool/error.txt"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","tls":"yes"}' >"$PKSB/spool/rig-request.json"
PATH="$PKSB/bin:$PATH" run_sourced "$PKSB" firstboot_consume_rig "$PKSB/spool" >/dev/null 2>&1
assert_rc "tls of the wrong type -> rc 1" "$?" "1"
assert_contains "the refusal names tls" "$(cat "$PKSB/spool/error.txt")" "tls must be true or false"
rm -f "$PKSB/spool/error.txt"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","tls":true,"tls_fingerprint":"abc"}' >"$PKSB/spool/rig-request.json"
PATH="$PKSB/bin:$PATH" run_sourced "$PKSB" firstboot_consume_rig "$PKSB/spool" >/dev/null 2>&1
assert_rc "a malformed fingerprint -> rc 1" "$?" "1"
assert_contains "the refusal names the fingerprint" "$(cat "$PKSB/spool/error.txt")" "tls_fingerprint"
rm -f "$PKSB/spool/error.txt"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","paired":1}' >"$PKSB/spool/rig-request.json"
PATH="$PKSB/bin:$PATH" run_sourced "$PKSB" firstboot_consume_rig "$PKSB/spool" >/dev/null 2>&1
assert_rc "paired of the wrong type -> rc 1" "$?" "1"
assert_contains "the refusal names paired" "$(cat "$PKSB/spool/error.txt")" "paired must be true or false"
rm -rf "$PKSB"
unset PKSB

echo "== unit: render_rig_miner_config — tls and the pin in pools[0] (#4065) =="
mk_tmpdir RKSB
mkdir -p "$RKSB/bin" "$RKSB/rigforge"
printf '#!/bin/bash\nexit 2\n' >"$RKSB/bin/getent"
chmod +x "$RKSB/bin/getent"
rk_fp="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
rk_tok="0123456789abcdef0123456789abcdef"
run_rk() { PITHEAD_RIGFORGE_DIR="$RKSB/rigforge" PATH="$RKSB/bin:$PATH" run_sourced "$RKSB" render_rig_miner_config >/dev/null 2>&1; }
printf '{"pool":"pool.example:5555","worker":"shed-3","access_token":"%s","tls":true,"tls_fingerprint":"%s"}' "$rk_tok" "$rk_fp" >"$RKSB/rig.json"
run_rk
assert_rc "render of a TLS pool -> rc 0" "$?" "0"
assert_eq "tls: true lands in pools[0]" "$(jq -r '.pools[0].tls' "$RKSB/rigforge/config.json")" "true"
assert_eq "the pin lands as pools[0]'s tls-fingerprint" "$(jq -r '.pools[0]["tls-fingerprint"]' "$RKSB/rigforge/config.json")" "$rk_fp"
printf '{"pool":"pool.example:5555","worker":"shed-3","access_token":"%s","tls":true}' "$rk_tok" >"$RKSB/rig.json"
run_rk
assert_eq "tls without a pin omits tls-fingerprint" "$(jq -r '.pools[0] | has("tls") and (has("tls-fingerprint") | not)' "$RKSB/rigforge/config.json")" "true"
printf '{"pool":"pool.example:5555","worker":"shed-3","access_token":"%s","tls_fingerprint":"%s"}' "$rk_tok" "$rk_fp" >"$RKSB/rig.json"
run_rk
assert_eq "a fingerprint without tls true emits neither key (RigForge refuses that pair)" "$(jq -c '.pools[0] | {tls: (has("tls")), fp: (has("tls-fingerprint"))}' "$RKSB/rigforge/config.json")" '{"tls":false,"fp":false}'
printf '{"pool":"pool.example:5555","worker":"shed-3","access_token":"%s","tls":false,"tls_fingerprint":"%s"}' "$rk_tok" "$rk_fp" >"$RKSB/rig.json"
run_rk
assert_eq "tls false emits no tls key and no pin" "$(jq -c '.pools[0] | {tls: (has("tls")), fp: (has("tls-fingerprint"))}' "$RKSB/rigforge/config.json")" '{"tls":false,"fp":false}'
printf '{"pool":"pool.example:5555","worker":"shed-3","access_token":"%s"}' "$rk_tok" >"$RKSB/rig.json"
run_rk
assert_eq "the plain-pool render is byte-for-byte the old shape" "$(jq -c '.pools' "$RKSB/rigforge/config.json")" '[{"url":"pool.example:5555","user":"shed-3"}]'
rm -rf "$RKSB"
unset RKSB rk_fp rk_tok
unset -f run_rk
