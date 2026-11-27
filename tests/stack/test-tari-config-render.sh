# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

: "${ROOT:?}" "${SANDBOX:?}"

echo "== unit: inject_service_configs renders build/tari/config.toml through a temp file =="
TCR="$SANDBOX/tari-config-render"
mkdir -p "$TCR/build/tari" "$TCR/elsewhere/dir"
make_stubs "$TCR/bin"
cp "$ROOT/build/tari/config.toml.template" "$TCR/build/tari/"
TCR_CFG="$TCR/build/tari/config.toml"
TCR_WANT=$(sed -e 's/<your_tari_onion_address_no_extension>/tcronion/g' -e 's/172\.28\.0/10.9.8/g' \
    "$TCR/build/tari/config.toml.template")
tcr_render() { PATH="$TCR/bin:$PATH" TARI_ONION=tcronion.onion NETWORK_PREFIX=10.9.8 run_sourced "$TCR" inject_service_configs >/dev/null 2>&1; }
tcr_check() {
    assert_eq "$1: config.toml is a regular file" "$([ -f "$TCR_CFG" ] && [ ! -L "$TCR_CFG" ] && echo regular)" "regular"
    assert_eq "$1: config.toml holds the rendered template" "$(cat "$TCR_CFG" 2>/dev/null)" "$TCR_WANT"
    assert_eq "$1: config.toml is readable by the container user" "$(file_mode "$TCR_CFG")" "644"
    assert_eq "$1: no temp file is left in build/tari" "$(find "$TCR/build/tari" -mindepth 1 | wc -l | tr -d ' ')" "2"
    assert_eq "$1: no render folder is left in build" "$(find "$TCR/build" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "1"
}

printf '#!/bin/sh\necho "$*" >>"%s/mktemp.log"\nexec %s "$@"\n' "$TCR" "$(command -v mktemp)" >"$TCR/bin/mktemp"
chmod +x "$TCR/bin/mktemp"
tcr_render
tcr_check "fresh render"
assert_eq "fresh render: the work happens in a private folder beside build/tari" "$(grep -c -- '-d build/.tari-render.XXXXXX' "$TCR/mktemp.log") $(grep -c 'build/tari/' "$TCR/mktemp.log")" "1 0"
assert_contains "fresh render: the onion name is filled in" "$(cat "$TCR_CFG")" "/onion3/tcronion:"

rm -f "$TCR_CFG"
(umask 077 && tcr_render)
tcr_check "tight umask"

printf 'keep\n' >"$TCR/elsewhere/file"
chmod 600 "$TCR/elsewhere/file"
rm -f "$TCR_CFG"
ln -s "$TCR/elsewhere/file" "$TCR_CFG"
tcr_render
tcr_check "link to a file"
assert_eq "link to a file: the file keeps its content" "$(cat "$TCR/elsewhere/file")" "keep"
assert_eq "link to a file: the file keeps its mode" "$(file_mode "$TCR/elsewhere/file")" "600"

rm -f "$TCR_CFG"
ln -s "$TCR/elsewhere/dir" "$TCR_CFG"
tcr_render
tcr_check "link to a folder"
assert_eq "link to a folder: the folder stays empty" "$(find "$TCR/elsewhere/dir" -mindepth 1 | wc -l | tr -d ' ')" "0"

rm -f "$TCR_CFG"
ln -s "$TCR/elsewhere/absent" "$TCR_CFG"
tcr_render
tcr_check "dangling link"
assert_eq "dangling link: the link target is not created" "$([ -e "$TCR/elsewhere/absent" ] || echo absent)" "absent"

mv "$TCR/build/tari/config.toml.template" "$TCR/elsewhere/template"
ln -s "$TCR/elsewhere/file" "$TCR/build/tari/config.toml.template"
tcr_out=$(PATH="$TCR/bin:$PATH" TARI_ONION=tcronion.onion NETWORK_PREFIX=10.9.8 run_sourced "$TCR" inject_service_configs 2>&1)
assert_contains "a linked template is not rendered, with a warning" "$tcr_out" "Could not render build/tari/config.toml from its template"
assert_eq "a linked template leaves config.toml as it was" "$(cat "$TCR_CFG")" "$TCR_WANT"
assert_eq "a linked template keeps the linked file's content and mode" "$(cat "$TCR/elsewhere/file") $(file_mode "$TCR/elsewhere/file")" "keep 600"
assert_eq "a linked template leaves nothing behind in build" "$(find "$TCR/build" -mindepth 1 | wc -l | tr -d ' ')" "3"

rm -f "$TCR/build/tari/config.toml.template"
tcr_out=$(PATH="$TCR/bin:$PATH" TARI_ONION=tcronion.onion NETWORK_PREFIX=10.9.8 run_sourced "$TCR" inject_service_configs 2>&1)
assert_contains "a missing template is not rendered, with a warning" "$tcr_out" "Could not render build/tari/config.toml from its template"
assert_eq "a missing template leaves config.toml as it was" "$(cat "$TCR_CFG")" "$TCR_WANT"
assert_eq "a missing template leaves nothing behind in build" "$(find "$TCR/build" -mindepth 1 | wc -l | tr -d ' ')" "2"

printf '#!/bin/sh\nexit 1\n' >"$TCR/bin/mktemp"
tcr_out=$(PATH="$TCR/bin:$PATH" TARI_ONION=tcronion.onion NETWORK_PREFIX=10.9.8 run_sourced "$TCR" inject_service_configs 2>&1)
assert_contains "a render folder that cannot be made is reported" "$tcr_out" "Could not create a render folder in build/"
assert_eq "a render folder that cannot be made leaves config.toml as it was" "$(cat "$TCR_CFG")" "$TCR_WANT"

assert_eq "quadlet tari units mount build/tari read-only" \
    "$(grep -c '^Volume=.*/build/tari:/var/tari/config:ro$' "$ROOT/os/quadlet/local/tari.container" "$ROOT/os/quadlet/payout/tari.container" | grep -c ':1$')" "2"
