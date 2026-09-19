# shellcheck shell=bash
# IT_DASHBOARD_PASSWORD (#2058) never renders onto the box, so none of lib.sh's redact()
# KEY=value/JSON vocabulary ever meets it — it is a harness-local credential the box side
# can't echo back. But the harness holds the exact VALUE, so scrub it by literal match
# wherever text passes through redact() or it_fail, independent of shape or key name.
# A no-op sed when the var is unset. Split out of lib.sh to fit the file-budget ratchet
# (docs/dev/file-budget.tsv) — ceilings only move down, so a new file, not a grown one.
redact_it_password() {
    if [ -n "${IT_DASHBOARD_PASSWORD:-}" ]; then
        sed "s/$(printf '%s' "$IT_DASHBOARD_PASSWORD" | sed 's/[][\.*^$\/]/\\&/g')/<redacted>/g"
    else
        cat
    fi
}
