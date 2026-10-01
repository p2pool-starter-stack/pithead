# shellcheck shell=bash
deploy_branch() {
    parent_lock_checkpoint deploy || die "Parent-held bench lock was lost before deploy."
    # #272: `pithead apply` runs `compose up --pull` (never --build), so it would test whatever images
    # were last built on the box, not this branch. `pithead upgrade` re-renders the generated configs
    # (inject_service_configs) AND rebuilds the first-party images from build/ (--build) before
    # recreating — so a Dockerfile/entrypoint change is under test. Unchanged chain nodes stay (#2639).
    log "Deploying the branch on $BENCH_HOST (pithead upgrade — re-render configs + rebuild first-party images)"
    deploy_keeping_chain || die "pithead upgrade failed in $E2E_DIR — branch did not deploy."
    # Record what was actually built, so "what did we test" is unambiguous in the run log (#272).
    on_bench "cd '$E2E_DIR' && docker compose images --format '{{.Service}} {{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null | grep -E 'p2pool|dashboard|monero|tor|xmrig' || true" | while IFS= read -r l; do step "image: $l"; done
    wait_bench_healthy 300 || warn "stack applied but not yet healthy; the harness will wait on real readiness signals"
    wait_synced 1500 || die "post-deploy chain readiness did not recover within 1500s; destructive phases refused."
    ok "branch deployed; stack reconciled"
}
