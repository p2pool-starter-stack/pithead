# shellcheck shell=bash
# The config-read-site extractor (#561), shared so there is exactly ONE of it.
#
# It walks the BUILT pithead for every config.json path the script reads, with a conservative
# fixed-shape parser that FAILS LOUD on a shape it does not recognize rather than skipping it.
# Two callers need the same answer and must not drift apart:
#
#   * test-config.sh asserts every path pithead READS exists in config.reference.json — the
#     closed-schema gate (#537) false-rejects a legitimate config otherwise.
#   * the same file's inverse row (#1929 follow-up) asserts every reference path pithead does NOT
#     read is one of the named config.json-only blocks — a path that renders no env var emits no
#     porcelain row, and the approval gate's env-diff allowlist cannot see it.
#
# A second spelling of this logic would be mutated in lockstep with nothing, so it lives here and
# both rows call it. Sourced by tests/stack/lib.sh.
#
# Sets DRIFT_FOUND (sorted, newline-separated, no leading dot) and DRIFT_BAD (1 = unrecognized
# shape, already reported via bad()). Needs $STACK.
#
# SC2034: DRIFT_EXCEPTIONS and DRIFT_BAD are read by the CALLERS in test-config.sh, across a
# source boundary the linter does not follow. (A comment line may not START with the linter's own
# name — it gets parsed as a directive, SC1073.)
# shellcheck disable=SC2034
config_read_sites() {
    # Deliberate exceptions: paths the extractor finds that need NO reference entry.
    # telegram.control.enabled (#2076): a REMOVED path, read only by
    # migrate_removed_telegram_control, which exists to DELETE it from an upgrading config.json.
    # Re-adding it to the reference would re-admit telegram.control as a committable path.
    # NOT `declare -a`: inside a function that makes it function-LOCAL, and the caller in
    # test-config.sh reads it across the source boundary — so a declared array is always
    # EMPTY there and every exception is silently ignored. Undetectable while the array was
    # empty (#2082); this is the first entry, and it reddened the #561 row until fixed.
    # A plain assignment, exactly like DRIFT_FOUND and DRIFT_BAD below.
    DRIFT_EXCEPTIONS=("telegram.control.enabled")

    DRIFT_FOUND="" # newline-separated normalized dotted paths (no leading dot), deduped at the end
    DRIFT_BAD=0

    drift_add_path() { # <.dotted.path> (leading dot optional)
        local p="${1#.}"
        # $'\n' rather than a literal line break: the continuation line of a multi-line
        # assignment sits at column 0, so re-indenting this block (as extracting it into a function
        # did) silently prepends that indent to EVERY stored path. The old `for p in $DRIFT_FOUND`
        # consumer word-split it away and never noticed; an exact-line `grep -qxF` does not.
        [ -n "$p" ] && DRIFT_FOUND="${DRIFT_FOUND}${p}"$'\n'
    }

    # Split a jq `//`-alternative chain into its parts and record each leading-dot part as a read
    # path. A part that isn't a path must be one of the literal default shapes this codebase uses
    # (empty/true/false/[]/{}, a quoted string, or a number) — anything else fails the whole test
    # loudly, naming the culprit, so a new default shape gets a deliberate look instead of a silent
    # pass-through.
    drift_classify_chain() { # <chain> <line-label>
        local chain="$1" line="$2" part
        while [ -n "$chain" ]; do
            if [[ "$chain" == *" // "* ]]; then
                part="${chain%% // *}"
                chain="${chain#* // }"
            else
                part="$chain"
                chain=""
            fi
            if [[ "$part" == .* ]]; then
                if [[ "$part" =~ ^\.[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
                    drift_add_path "$part"
                else
                    bad "config-read extractor (#561)" "unrecognized path shape '$part' in $line — extend the extractor"
                    DRIFT_BAD=1
                fi
            elif [ "$part" = "empty" ] || [ "$part" = "true" ] || [ "$part" = "false" ] || [ "$part" = "[]" ] || [ "$part" = "{}" ]; then
                : # known default literal, not a path
            elif [[ "$part" =~ ^\"[^\"]*\"$ ]] || [[ "$part" =~ ^-?[0-9]+$ ]]; then
                : # quoted-string or numeric default
            else
                bad "config-read extractor (#561)" "unrecognized default shape '$part' in $line — extend the extractor"
                DRIFT_BAD=1
            fi
        done
    }

    # config_bool '<path>' <default> call sites (pithead's null-aware boolean reader) — the path arg
    # is always a plain single-quoted leading-dot literal.
    while IFS= read -r p; do
        drift_add_path "$p"
    done < <(grep -a -oE "config_bool '\.[A-Za-z0-9_.]+'" "$STACK" | sed -E "s/^config_bool '(.*)'\$/\1/")

    # Single-line jq reads against $CONFIG_FILE. Filtered down to genuine simple `config_get`-style
    # reads: this excludes multi-line validator blocks (an unterminated quote leaves an odd '-count on
    # its opening/closing line), writes (`= $var`), and the closed-schema gate's own whole-block
    # --slurpfile comparisons (those compare already-covered blocks wholesale, not a new leaf path).
    while IFS=: read -r lineno text; do
        [[ "$text" == *'--slurpfile'* ]] && continue
        [[ "$text" == *' = $'* ]] && continue
        [[ "$text" == *'jq'* ]] || continue
        qcount=$(grep -o "'" <<<"$text" | wc -l)
        [ "$qcount" -eq 2 ] || continue
        filter="${text#*\'}"
        filter="${filter%\'*}"
        # In scope only if the filter is itself a path read: a bare path, a parenthesized
        # `(path // default)` prefix, or an `if path <op> ...` boolean read. Anything else (`.`,
        # `any(..|strings;...)`, an array-literal walk like `[(.path // [])[] | .name] | group_by(.)`)
        # is a structural check or a nested-element walk, not a new top-level path — out of scope.
        if [[ "$filter" == .* ]]; then
            drift_classify_chain "$filter" "pithead:$lineno"
        elif [[ "$filter" == \(* ]]; then
            # Only the parenthesized `(path // default)` prefix is attributed; whatever follows the
            # closing paren (e.g. `[] | select(.name == $n) | .host // ""`) is relative to an
            # iterated element, not a new root path — deliberately not walked further.
            inner="${filter#\(}"
            inner="${inner%%\)*}"
            drift_classify_chain "$inner" "pithead:$lineno"
        elif [[ "$filter" == "if "* ]]; then
            while IFS= read -r tok; do
                [ -n "$tok" ] && drift_add_path "$tok"
            done < <(grep -oE '\.[A-Za-z_][A-Za-z0-9_.]*(\[[^]]*\])?[[:space:]]+(!=|==)' <<<"$filter" |
                sed -E 's/(\[[^]]*\])?[[:space:]]+(!=|==)$//')
        fi
    done < <(grep -a -n '"\$CONFIG_FILE"' "$STACK")

    DRIFT_FOUND="$(sort -u <<<"$DRIFT_FOUND")"
}
