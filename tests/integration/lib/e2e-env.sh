# shellcheck shell=bash
# The one line bench-ci's tier4-e2e reads to tell a run the bench stopped from a run the branch
# failed (#2643, bench-ci#613). It used to grep this harness's prose, and a reworded warning turned
# an environment abort into a branch failure. The contract is a fixed line on stdout, alone
# (indentation allowed; no [ITEST], no `!`, no colour codes):
#
#   e2e-env: <key>
#
# printed only where the harness stops because of the bench, and at most once per run. The keys,
# and the only places that print them:
#
#   workers-offline    skip-accounting.sh assert_mining_state: a --check run found 0 workers
#                      online. bench-ci accepts it in its check mode only.
#   tari-not-done      e2e.sh wait_synced (deploy_branch's post-deploy wait) gave up, or the readiness
#                      phase's `Tari is synced` assertion (run-scenario.sh) refused, with the Tari
#                      panel still loading or syncing. bench-ci retries this one once.
#   tari-sync-timeout  lib.sh assert_tari_synced_required failed on a Tari still loading or syncing
#                      after wait_tari_synced timed out, in local-pruned-main-secure-tari only.
#   readiness          detached-harness.sh harness_pregate: the readiness phase refused the
#                      destructive phases for any reason but Tari. Never its check phase, which
#                      runs against the deployed branch.
#   chains-behind      e2e.sh preflight: the bench chains are not at tip (#914).
#
# A dashboard that does not answer is never the bench's here: the branch may have broken it.
# A line of any other shape, or another key, excuses nothing on bench-ci. So no other output of the
# harness may carry the line's prefix; e2e.sh strips it from the heartbeat tail so the full-log
# replay is its only copy. The guard below holds within one process; harness_pregate, the one place
# a second process could add a line, prints its own only when the readiness phase printed none.
E2E_ENV_SENT=""
e2e_env() { # <key>
    case "$1" in
    workers-offline | tari-not-done | tari-sync-timeout | readiness | chains-behind) ;;
    *) return 1 ;;
    esac
    [ -z "$E2E_ENV_SENT" ] || return 0
    E2E_ENV_SENT="$1"
    printf 'e2e-env: %s\n' "$1"
}
