# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

run_cli_wizard_eof() {
    local script out rc
    script=$(
        cat <<'BASH'
set -uo pipefail
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-eof.XXXXXX") || exit 1
trap 'rm -f "$work/config.json" "$work/original" "$work/stdout" "$work/stderr"; rmdir "$work"' EXIT
printf '{ "preserve": "existing configuration" }\n\n' >"$work/original"
for chain in Monero Tari; do
    for ending in empty partial valid-partial; do
        for existing in absent present; do
            rm -f "$work/config.json"
            [ "$existing" = absent ] || cp "$work/original" "$work/config.json"
            {
                [ "$chain" = Monero ] || printf '%s\n\n2\n' "$monero"
                case "$ending" in
                empty) : ;;
                partial) printf garbage ;;
                valid-partial)
                    if [ "$chain" = Monero ]; then printf '%s' "$monero"; else printf '%s' "$tari"; fi
                    ;;
                esac
            } | (
                PITHEAD_CONFIG_FILE="$work/config.json"
                source "$cli"
                wizard_ask_core
                wizard_ask_shape
                wizard_write_config
            ) >"$work/stdout" 2>"$work/stderr"
            rc=$?
            if [ "$rc" != 1 ] ||
                ! grep -Fq "End of input while reading the $chain payout address. Aborting." "$work/stderr"; then
                printf 'FAIL: %s %s EOF (%s config) did not abort at its payout prompt\n' "$chain" "$ending" "$existing"
                exit 1
            fi
            if [ "$existing" = present ]; then
                cmp -s "$work/original" "$work/config.json" || exit 1
            else
                [ ! -e "$work/config.json" ] || exit 1
            fi
        done
    done
done
BASH
    )
    out=$(rx "cli=$(quote_arg "$IT_PITHEAD"); monero=$(quote_arg "$1"); tari=$(quote_arg "$2"); $script" 2>&1)
    rc=$?
    assert_rc "CLI payout EOF aborts at both prompts without creating or overwriting configuration" "$rc" 0
    [ "$rc" = 0 ] || {
        it_err "$out"
        return 1
    }
}
