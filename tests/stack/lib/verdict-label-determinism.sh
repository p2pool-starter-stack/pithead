# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is sourced by tests/stack/test-harness-tooling.sh}"

echo "== unit: verdict-line determinism — every PASS label, not two named lines (#1740) =="
# The two named nondeterministic PASS lines in test-harness-tooling.sh pin their values BY NAME, and
# nothing looks for a third — N grew from one to two by discovery, so the multiset proof still rests
# on an enumeration no instrument can show is complete. A PASS verdict line is exactly
# `  <glyph> <label>` (lib.sh's ok() prints its first argument and nothing else), so a value can only
# reach one through the LABEL. That makes the whole set checkable statically, in one pass, with no
# sampling — which matters twice over. Two samples miss a value that changes only SOMETIMES: #1709's
# own heartbeat line read clean across two samples that happened to land on the same second. And the
# domains most likely to carry a measurement cannot be sampled in isolation at all —
# test-spool-audit.sh is a deliberate consumer of another domain's $C and refuses a standalone
# source, so there is nothing to run twice.
#
# So hold the set of PASS labels that interpolate ANYTHING against a reviewed expectation. Keyed on
# the interpolated NAME, not the label prose: rewording a label is routine and must not red the
# suite, while a genuinely new interpolation must. `bad` is excluded — its label prints only on the
# failure path, which no multiset proof compares.
vd_interp_names() { # <file...> -> "<basename>|<name>", once per distinct interpolated name
    awk '
    {
        stripped = $0
        sub(/^[ \t]+/, "", stripped)
        # Heredoc BODY is data, not code. Without this the fixture written a few lines below —
        # which has to contain an emitter call to be a control at all — is scanned as if it were
        # source, and the sweep reports its name against a file that never emits it. `<<<` is a
        # here-STRING and opens nothing.
        if (hd != "") { if (stripped == hd) hd = ""; next }
        if (match($0, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/) && $0 !~ /<<</) {
            tag = substr($0, RSTART, RLENGTH)
            sub(/^<<-?[ \t]*/, "", tag)
            gsub(/[\047"]/, "", tag)
            hd = tag
            next
        }
        if (stripped ~ /^#/) next
        if (!match($0, /(^|[^A-Za-z0-9_])(ok|assert_eq|assert_contains|assert_not_contains|assert_rc)[ \t]+"/)) next
        rest = substr($0, RSTART + RLENGTH)
        label = ""
        n = length(rest)
        for (j = 1; j <= n; j++) {
            c = substr(rest, j, 1)
            if (c == "\\") { j++; continue }
            if (c == "\"") break
            label = label c
        }
        f = FILENAME
        sub(/^.*\//, "", f)
        while (match(label, /\$\{?[A-Za-z_][A-Za-z0-9_]*|\$\{?[0-9]+|\$[@*#]|\$\(|`/)) {
            tok = substr(label, RSTART, RLENGTH)
            label = substr(label, RSTART + RLENGTH)
            if (tok == "$(" || tok == "`") { print f "|$(cmd)"; continue }
            gsub(/[${]/, "", tok)
            print f "|" tok
        }
    }
    ' "$@" | LC_ALL=C sort -u
}

# Every entry below was read at its call site and is a loop variable over a fixed list, a count
# derived from the tree, or a value parsed out of a repo file — the same on every run of a given
# tree. The four that are NOT run-invariant are called out in #1740: test-appliance-os-update.sh's
# RIS/RIJ are absolute paths that differ per WORKTREE, and test-secrets.sh's mem/host_ram_mb come
# from /proc/meminfo MemTotal, so they differ per BOX. Both are stable across two runs in one place,
# which is exactly why sampling never found them.
#
# THE NUMBERED ENTRIES ARE A DIFFERENT CLASS AND CARRY A DIFFERENT PROOF (#1767). A label built from
# a POSITIONAL is a WRAPPER's label: what actually prints is whatever its callers pass, which this
# file cannot see. So the sweep flags the wrapper and the review has to go to the callers. Done
# mechanically — every call of the TWELVE wrappers, with backslash continuations joined, argument
# extracted by a shell-grammar parser rather than by eye: 87 calls, 86 passing a bare string
# literal, and one passing `${ev}` from test-control-editable-allowlist.sh's loop over 25
# spelled-out event names. That one is a loop variable over a fixed list, so the whole class is
# run-invariant today.
#   * COUNT THE WRAPPERS, NOT THE ROWS. The first pass said "eight wrappers, 55 calls" because it
#     counted ROWS: a row is <file>|<index>, so test-config.sh|2 collapses three wrappers and
#     test-rig-worker.sh|3 three more. Twelve and 87 are the numbers the imperative below is about;
#     auditing eight misses four. The verdict held at the wider scope, its supporting sentence did
#     not.
#   * `lib.sh|1` is not a call site at all — it is assert_eq/assert_contains/assert_not_contains/
#     assert_rc forwarding their <label> to ok(); every label funnels through it, so it is listed
#     for completeness and says nothing about any one domain.
# WHAT THIS ROW STILL DOES NOT PROVE: it pins the SET of interpolating labels, not the VALUES. A new
# caller handing one of these wrappers a measured value keeps the set identical and the row green —
# the caller audit above is a point-in-time reading, not a standing instrument. Re-run it when a
# wrapper gains callers; that is the residual #1740 could not close and this row does not either.
# The special-parameter class has no live site beyond $@ — no label in tests/stack uses $* or $#.
# They are seeded below anyway, so all three characters have a control that can fail rather than two
# branches that pass by construction.
vd_expected="$(
    cat <<'VDEXP'
lib.sh|1
test-appliance-boot.sh|ph
test-appliance-hostname.sh|mode
test-appliance-hostname.sh|op
test-appliance-identity-boot.sh|cli_pages
test-appliance-identity-boot.sh|u
test-appliance-identity.sh|1
test-appliance-identity.sh|f
test-appliance-os-update.sh|RIJ
test-appliance-os-update.sh|RIS
test-config.sh|2
test-config.sh|bad_port
test-config.sh|checked
test-config.sh|core_checked
test-confirm-approval.sh|secret_key
test-control-add-only-ssrf.sh|2
test-control-add-only-ssrf.sh|3
test-control-core.sh|reowned
test-control-diagnostics.sh|_c
test-control-diagnostics.sh|_diag_container
test-control-editable-allowlist.sh|1
test-control-editable-allowlist.sh|k
test-control-perimeter-tier3.sh|label
test-doctor.sh|ip
test-recovery-address-gates.sh|_rag_v
test-recovery-address-gates.sh|label
test-release.sh|comp
test-release.sh|pin_rel
test-release.sh|svc
test-render-quadlet.sh|f
test-rig-worker.sh|3
test-secrets-masking.sh|1
test-secrets.sh|ev
test-secrets.sh|host_ram_mb
test-secrets.sh|mem
test-spool-audit.sh|audit_lines
test-spool-audit.sh|audit_size
test-tor-network.sh|v
test-unit-helpers.sh|t_human
test-unit-helpers.sh|t_name
test-unit-helpers.sh|t_val
VDEXP
)"
mapfile -t stack_fragments < <(find "$ROOT/tests/stack" -type f -name 'test-*.sh' | sort)
assert_eq "every PASS label that interpolates a value is one the suite has reviewed" \
    "$(vd_interp_names "$ROOT/tests/stack/lib.sh" "${stack_fragments[@]}")" "$vd_expected"

# The row above is an equality over a set, so a sweep that silently stopped matching would report
# an empty actual against a non-empty expectation and fail loudly — but it would fail naming the
# wrong cause. These three drive the extractor over a file written for the purpose, so each
# property that the row depends on is asserted separately and a break says which one went.
vd_seed="$SANDBOX/vd-interp-control"
mkdir -p "$vd_seed"
cat >"$vd_seed/test-vd-seed.sh" <<'VDSEED'
ok "a label carrying a brand new interpolation $vd_fresh_name"
ok "an escaped \$PWD is prose in a label, not an interpolation"
ok "a wrapper label built from a positional $1 and a braced one ${2}"
ok "a label splicing all of its arguments $@"
ok "a label naming $* and $# — no live site, seeded so the branch has a control"
bad "a bad-only label naming $vd_failure_only"
VDSEED
vd_ctl="$(vd_interp_names "$vd_seed/test-vd-seed.sh")"
assert_contains "the sweep reports a new interpolated PASS label (firing control)" "$vd_ctl" "vd_fresh_name"
assert_not_contains "an escaped dollar in a label is not read as interpolation" "$vd_ctl" "PWD"
assert_not_contains "a bad-only label is not held to the PASS-line rule" "$vd_ctl" "vd_failure_only"
# #1767: the positional and special-parameter alternations are the two this extractor did NOT have.
# Assert them separately from the $VAR row above, so a break says which class stopped matching.
assert_contains "the sweep reports a positional interpolation (#1767 firing control)" "$vd_ctl" "|1"
assert_contains "the sweep reports a braced positional too" "$vd_ctl" "|2"
assert_contains "the sweep reports \$@, which splices every argument" "$vd_ctl" "|@"
assert_contains "the sweep reports \$*, the other splicing parameter" "$vd_ctl" "|*"
assert_contains "the sweep reports \$#, the argument count" "$vd_ctl" "|#"
unset -f vd_interp_names
unset vd_expected vd_seed vd_ctl
