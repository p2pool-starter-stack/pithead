#!/usr/bin/env bash
set -euo pipefail
echo "== candidate-compatible reset recovery fixture =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$HERE/../tools/reset-recovery-fixture.sh"
d=$(mktemp -d "${TMPDIR:?}/reset-recovery-selftest.XXXXXXXX")
trap 'rm -rf "$d"' EXIT
cd "$d"
mkdir scratch
printf '%s\n' '{"config_version":"9.9.9","mining":{"wallet":"fixture-wallet","payout_address":"fixture-payout","payout_view_key":"fixture-view"},"tari":{"mode":"off"},"future_setting":true}' >config.json
cp config.json original.json
printf '%s\n' '{"_docs":{},"config_version":"2.0.0","mining":{"wallet":"placeholder","payout_address":"placeholder","payout_view_key":"placeholder"},"tari":{"mode":"off","wallet_address":"placeholder"}}' >config.reference.json
cat >pithead <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>calls
[ "${FAIL_COMMAND:-}" != "$1" ]
if [ "$1" = apply ] && ! jq -e '.config_version != null and .config_version != "1.0.0"' config.json >/dev/null; then
    jq '.config_version="2.0.0"' config.json >stamped.json
    mv stamped.json config.json
fi
CLI
chmod +x pithead
bash "$helper" scratch ./pithead prepare
cmp -s original.json scratch/original.json
jq -e '.config_version == "2.0.0" and .mining == {"wallet":"fixture-wallet","payout_address":"fixture-payout","payout_view_key":"fixture-view"} and .tari == {"mode":"off"} and (has("future_setting") | not)' config.json >/dev/null
bash "$helper" scratch ./pithead restore
cmp -s original.json config.json
bash "$helper" scratch ./pithead remove
test ! -e scratch
printf 'PASS newer baseline projects without placeholders and cleanup restores original bytes\n'
for value in '"unsupported-wallet"' null false; do
    mkdir scratch
    jq --argjson value "$value" '.future_wallet=$value' original.json >config.json
    cp config.json unsupported.json
    if bash "$helper" scratch ./pithead prepare; then exit 1; fi
    cmp -s unsupported.json config.json
    test ! -e scratch/mutated
    bash "$helper" scratch ./pithead restore
    bash "$helper" scratch ./pithead remove
done
printf 'PASS unsupported wallet fields refuse before mutation, including null and false\n'
for command in down apply up; do
    cp original.json config.json
    mkdir scratch
    bash "$helper" scratch ./pithead prepare
    if FAIL_COMMAND="$command" bash "$helper" scratch ./pithead restore; then exit 1; fi
    cmp -s original.json scratch/original.json
    bash "$helper" scratch ./pithead restore
    cmp -s original.json config.json
    bash "$helper" scratch ./pithead remove
done
printf 'PASS down, apply and up cleanup failures retain original recovery copy\n'
jq '.config_version="1.0.0"' original.json >config.json
cp config.json older.json
mkdir scratch
bash "$helper" scratch ./pithead prepare
bash "$helper" scratch ./pithead restore
cmp -s older.json config.json
bash "$helper" scratch ./pithead remove
printf 'PASS cleanup preserves original bytes after apply changes the stamp\n'
