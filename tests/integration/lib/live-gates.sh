# shellcheck shell=bash
# The cross-version image-upgrade gate. The XvB routing gate lives with its own helpers in
# live-xvb-support.sh; both are sourced by run.sh through this file.
# shellcheck source=tests/integration/lib/live-upgrade-support.sh
source "$HERE/lib/live-upgrade-support.sh"
# shellcheck source=tests/integration/lib/live-state-support.sh
source "$HERE/lib/live-state-support.sh"
# shellcheck source=tests/integration/lib/live-xvb-support.sh
source "$HERE/lib/live-xvb-support.sh"
run_image_upgrade() {
    # shellcheck disable=SC2034 # read by lib.sh's reporters to label assertions and artifacts
    IT_CURRENT_SCENARIO="image-upgrade"
    echo ""
    it_log "── cross-version image upgrade phase ────────────────"

    local before_state before_rev before_images before_revisions before_secrets before_workers before_telemetry candidate_refs fails_before="$IT_FAIL"
    local before_monero before_monero_tip before_tari before_monero_dir before_tari_dir before_monero_id before_tari_id before_mounts before_all_refs candidate_all_refs
    before_state="$(api_state)"
    before_rev="$(dashboard_image_revision)"
    before_images="$(compose_image_ids)"
    before_revisions="$(first_party_revisions)"
    if ! before_secrets="$(upgrade_secret_fingerprints)"; then
        it_fail "upgrade secret/onion fingerprints readable" \
            "a required .env category or Tor onion-key file set is absent/unreadable; upgrade not attempted"
        return 0
    fi
    before_workers="$(worker_names)"
    before_telemetry="$UPGRADE_BEFORE_TELEMETRY"
    if [ -z "$before_telemetry" ]; then
        it_fail "archived pre-upgrade durable dashboard state is readable" "required tables are absent from the safety archive; upgrade not attempted"
        return 0
    fi
    before_monero_tip="$(monero_chain_tip)"
    before_monero="${before_monero_tip%% *}"
    before_monero_id="${before_monero_tip#* }"
    before_tari="$(jq_get "$before_state" '.sync.tari.current')"
    before_monero_dir="$(env_on_box MONERO_DATA_DIR)"
    before_tari_dir="$(env_on_box TARI_DATA_DIR)"
    before_mounts="$(stateful_mounts)" || before_mounts=""
    before_all_refs="$(all_running_refs)" || before_all_refs=""

    if [ "$(jq_get "$before_state" '.sync.monero.state')" != "done" ] ||
        [ "$(jq_get "$before_state" '.sync.tari.state')" != "done" ] ||
        ! chain_tip_valid "$before_monero_tip" || ! height_continues 1 "$before_tari" ||
        [ "$(jq_get "$before_state" '.proxy_workers')" -lt "$EXPECTED_WORKERS" ] 2>/dev/null ||
        [ "$(jq_get "$before_state" '.stratum.total_hashes')" -le 0 ] 2>/dev/null; then
        it_fail "upgrade starts from synced chains and active mining" \
            "run --check first; need both sync states done, positive heights/hashes, and >=$EXPECTED_WORKERS workers"
        return 0
    fi
    it_pass "upgrade starts from synced chains and active mining"

    before_tari_id="$(tari_block_identity "$before_tari")"
    if [ -z "$before_monero_id" ] || [ -z "$before_tari_id" ]; then
        it_fail "pre-upgrade chain identities are readable" "could not read the Monero or Tari block hash; upgrade not attempted"
        return 0
    fi
    it_pass "pre-upgrade Monero and Tari block identities captured"

    if ! revision_matches_sha "$before_rev" "$IMAGE_UPGRADE_FROM_SHA"; then
        it_fail "running image revision matches the declared old Pithead commit" \
            "image reports [$before_rev], expected exactly $IMAGE_UPGRADE_FROM_SHA; upgrade not attempted"
        return 0
    fi
    it_pass "running image revision matches the declared old Pithead commit ($before_rev)"
    if revisions_match_sha "$before_revisions" "$IMAGE_UPGRADE_FROM_SHA"; then
        it_pass "every running first-party image matches the declared old Pithead commit"
    else
        it_fail "every running first-party image matches the declared old Pithead commit" \
            "required services are absent or at least one OCI revision does not match; upgrade not attempted"
        return 0
    fi
    if ! prepare_candidate_bundle; then
        [ -z "$UPGRADE_STAGE_DIR" ] || rm -rf "$UPGRADE_STAGE_DIR"
        UPGRADE_STAGE_DIR=""
        it_fail "candidate bundle and images verify against the external trust root" \
            "bundle signature, key continuity, pinned refs, or an image signature failed; upgrade not attempted"
        return 0
    fi
    candidate_refs="$UPGRADE_CANDIDATE_REFS"
    candidate_all_refs="$(candidate_refs_for_running_set "$before_all_refs")" || candidate_all_refs=""
    if [ -z "$before_mounts" ] || [ -z "$before_all_refs" ] || [ -z "$candidate_all_refs" ]; then
        rm -rf "$UPGRADE_STAGE_DIR"
        UPGRADE_STAGE_DIR=""
        it_fail "pre-upgrade mounts and full running image set captured" "stateful mounts or candidate refs are incomplete; upgrade not attempted"
        return 0
    fi
    it_pass "candidate bundle, every compose digest, first-party signatures, and exact revisions verify externally"

    {
        printf 'from_pithead_sha: %s\n' "$IMAGE_UPGRADE_FROM_SHA"
        printf 'from_dashboard_revision: %s\n' "$before_rev"
        printf 'candidate_version: %s\n' "$(tr -d '\n' <"$UPGRADE_STAGE_DIR/pithead/VERSION")"
        printf 'candidate_commit: %s\n' "$(tr -d '\n' <"$UPGRADE_STAGE_DIR/pithead/PITHEAD_COMMIT")"
        printf 'candidate_bundle_sha256: %s\n' "$(sha256_file "$UPGRADE_BUNDLE_SNAPSHOT")"
        printf 'candidate_signature_sha256: %s\n' "$(sha256_file "$UPGRADE_SIGNATURE_SNAPSHOT")"
        printf 'trusted_key_sha256: %s\n' "$(sha256_file "$UPGRADE_TRUSTED_KEY")"
        printf 'monero_anchor: %s %s\n' "$before_monero" "$before_monero_id"
        printf 'tari_anchor: %s\n' "$before_tari_id"
        printf '%s\n' "$before_revisions"
        printf '%s\n' "$UPGRADE_CANDIDATE_ALL_REFS"
        printf '%s\n' "$before_images"
    } >"$OUT_DIR/image-upgrade-provenance.txt"

    if ! UPGRADE_BEFORE_REFS="$(all_running_refs)"; then
        rm -rf "$UPGRADE_STAGE_DIR"
        UPGRADE_STAGE_DIR=""
        it_fail "pre-upgrade running image refs captured for rollback" "required running image refs are unreadable; upgrade not attempted"
        return 0
    fi
    printf 'baseline_running_refs:\n%s\n' "$UPGRADE_BEFORE_REFS" >>"$OUT_DIR/image-upgrade-provenance.txt"
    UPGRADE_BEFORE_REVISIONS="$before_revisions"
    UPGRADE_BEFORE_DERIVED="$(derived_state_fingerprint)" || UPGRADE_BEFORE_DERIVED=""
    UPGRADE_BEFORE_SECRETS="$before_secrets"
    UPGRADE_BEFORE_TELEMETRY="$before_telemetry"
    UPGRADE_BEFORE_MOUNTS="$before_mounts"
    UPGRADE_BEFORE_WORKERS="$before_workers"
    UPGRADE_BEFORE_MONERO="$before_monero" UPGRADE_BEFORE_TARI="$before_tari"
    UPGRADE_BEFORE_MONERO_ID="$before_monero_id" UPGRADE_BEFORE_TARI_ID="$before_tari_id"
    if [ -z "$UPGRADE_BEFORE_DERIVED" ]; then
        [ -z "$UPGRADE_STAGE_DIR" ] || rm -rf "$UPGRADE_STAGE_DIR"
        UPGRADE_STAGE_DIR="" UPGRADE_ROLLBACK_DIR=""
        it_fail "pre-upgrade derived host state captured for rollback" "could not fingerprint generated state; upgrade not attempted"
        return 0
    fi
    if ! prepare_baseline_install; then
        rm -rf "$UPGRADE_STAGE_DIR"
        UPGRADE_STAGE_DIR="" UPGRADE_ROLLBACK_DIR=""
        it_fail "versioned baseline layout validated for exact rollback" "the live target must be a current -> pithead-v* layout"
        return 0
    fi
    if ! pithead down >/dev/null 2>&1 || ! capture_state_snapshots "$before_mounts"; then
        rm -rf "$UPGRADE_STAGE_DIR"
        UPGRADE_STAGE_DIR="" UPGRADE_ROLLBACK_DIR=""
        it_fail "quiesced writable state captured in private CoW snapshots" "the stack must stop cleanly and every stateful mount must support cp --reflink=always; upgrade not attempted"
        return 0
    fi
    arm_upgrade_abort_restore
    if ! prepare_candidate_install; then
        it_fail "candidate staged in a fresh immutable version directory" "the live target must be a current -> pithead-v* layout with a free candidate version path"
        restore_upgrade_baseline || true
        return 0
    fi
    it_pass "verified candidate staged in a fresh version directory with exact rollback armed"

    it_step "running the candidate's supported pithead upgrade path…"
    if ! strict_pithead upgrade 2>&1 | redact >"$OUT_DIR/image-upgrade.log"; then
        it_fail "pithead upgrade succeeded" "see $OUT_DIR/image-upgrade.log"
        capture_artifacts "image-upgrade" "$OUT_DIR"
        return 0
    fi
    wait_status_ok 300 || it_fail "stack recovered after image upgrade" "pithead status did not become healthy"
    wait_monero_synced 300 || it_fail "Monero resynchronized after image upgrade" "sync did not reach done"
    wait_tari_synced 300 || it_fail "Tari resynchronized after image upgrade" "sync did not reach done"
    [ "$SKIP_MINING_ASSERTS" = "1" ] || wait_for 240 5 "the exact pre-upgrade worker set" _pred_worker_set "$before_workers" || it_fail "workers returned after image upgrade" "the exact pre-upgrade worker set did not return"
    [ "$SKIP_MINING_ASSERTS" = "1" ] || wait_hashes_flowing 360 || it_fail "hashes resumed after image upgrade" "stratum hashes stayed idle"

    local after_state after_monero after_monero_id after_monero_tip after_rev after_images after_revisions after_refs after_all_refs after_secrets after_workers after_telemetry missing_workers name safe_name
    after_state="$(api_state)"
    after_rev="$(dashboard_image_revision)"
    after_images="$(compose_image_ids)"
    after_revisions="$(first_party_revisions)"
    after_refs="$(first_party_running_refs)"
    after_all_refs="$(all_running_refs)"
    after_monero_tip="$(monero_chain_tip)"
    after_monero="${after_monero_tip%% *}"
    after_monero_id="${after_monero_tip#* }"
    if ! after_secrets="$(upgrade_secret_fingerprints)"; then
        it_fail "upgrade secret/onion fingerprints readable after upgrade" \
            "a required .env category or Tor onion-key file set is absent/unreadable"
        after_secrets="UNREADABLE"
    fi
    after_workers="$(worker_names)"
    if ! after_telemetry="$(dashboard_durable_rows "$UPGRADE_TELEMETRY_EPOCH")"; then
        it_fail "post-upgrade durable dashboard state is readable" "required tables are absent or unreadable"
        after_telemetry="UNREADABLE"
    fi
    {
        printf 'to_pithead_sha: %s\n' "$IMAGE_UPGRADE_TO_SHA"
        printf 'to_dashboard_revision: %s\n' "$after_rev"
        printf 'monero_after: %s %s\n' "$after_monero" "$after_monero_id"
        printf 'tari_after: %s\n' "$(tari_block_identity "$(jq_get "$after_state" '.sync.tari.current')")"
        printf '%s\n' "$after_revisions"
        printf '%s\n' "$after_all_refs"
        printf '%s\n' "$after_refs"
        printf '%s\n' "$after_images"
    } >>"$OUT_DIR/image-upgrade-provenance.txt"

    if revision_matches_sha "$after_rev" "$IMAGE_UPGRADE_TO_SHA"; then
        it_pass "upgraded image revision matches the declared new Pithead commit ($after_rev)"
    else
        it_fail "upgraded image revision matches the declared new Pithead commit" \
            "image reports [$after_rev], expected exactly $IMAGE_UPGRADE_TO_SHA"
    fi
    assert_eq "running first-party containers use the signed digest-pinned candidate refs" "$after_refs" "$candidate_refs"
    assert_eq "every running container uses its signed-bundle digest" "$after_all_refs" "$candidate_all_refs"
    if [ "$(printf '%s\n' "$after_revisions" | cut -d' ' -f1)" = "$(printf '%s\n' "$before_revisions" | cut -d' ' -f1)" ] &&
        revisions_match_sha "$after_revisions" "$IMAGE_UPGRADE_TO_SHA"; then
        it_pass "every running first-party image matches the declared new Pithead commit"
    else
        it_fail "every running first-party image matches the declared new Pithead commit" \
            "the first-party service set changed or at least one OCI revision is absent/wrong"
    fi
    assert_ne "the running first-party image set changed" "$after_images" "$before_images"
    assert_eq "Monero data path reused across image versions" "$(env_on_box MONERO_DATA_DIR)" "$before_monero_dir"
    assert_eq "Tari data path reused across image versions" "$(env_on_box TARI_DATA_DIR)" "$before_tari_dir"
    assert_eq "persistent mounts stayed stable or moved to the candidate's copied internal state" \
        "$(normalized_stateful_mounts "$UPGRADE_CANDIDATE_DIR" "$(stateful_mounts)")" \
        "$(normalized_stateful_mounts "$UPGRADE_BASELINE_DIR" "$before_mounts")"
    assert_eq "captured Monero chain prefix survived the upgrade" "$(monero_block_identity "$((before_monero - 1))")" "$before_monero_id"
    assert_eq "Tari chain identity survived the upgrade" "$(tari_block_identity "$before_tari")" "$before_tari_id"
    if chain_tip_valid "$after_monero_tip" && height_continues "$before_monero" "$after_monero"; then
        it_pass "Monero retained the captured canonical prefix and did not regress"
    else
        it_fail "Monero retained the captured canonical prefix and did not regress" \
            "before [$before_monero], after [$after_monero]"
    fi
    if height_continues "$before_tari" "$(jq_get "$after_state" '.sync.tari.current')"; then
        it_pass "Tari retained the captured canonical prefix and did not regress"
    else
        it_fail "Tari retained the captured canonical prefix and did not regress" \
            "before [$before_tari], after [$(jq_get "$after_state" '.sync.tari.current')]"
    fi
    if [ "$(jq_get "$after_state" '.sync.monero.state')" = "done" ] && [ "$(jq_get "$after_state" '.sync.tari.state')" = "done" ]; then
        it_pass "both chains report synced after the image upgrade"
    else
        it_fail "both chains report synced after the image upgrade" "Monero or Tari sync state is not done"
    fi
    if [ "$after_secrets" = "$before_secrets" ]; then
        it_pass "wallet/proxy/dashboard/RPC/onion fingerprints survived the upgrade"
        printf '%s\n' 'wallet/proxy/dashboard/RPC/onion categories: unchanged' >"$OUT_DIR/image-upgrade-secret-continuity.txt"
    else
        it_fail "wallet/proxy/dashboard/RPC/onion fingerprints survived the upgrade" "one or more categories changed; digest values are intentionally not recorded"
        printf '%s\n' 'wallet/proxy/dashboard/RPC/onion categories: mismatch' >"$OUT_DIR/image-upgrade-secret-continuity.txt"
    fi
    missing_workers=""
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if ! grep -Fqx -- "$name" <<<"$after_workers"; then
            safe_name="$(printf '%s' "$name" | LC_ALL=C tr -d '[:cntrl:]' | cut -c1-80)"
            missing_workers="${missing_workers}${missing_workers:+,}${safe_name:-<non-printing-name>}"
        fi
    done <<<"$before_workers"
    assert_eq "pre-upgrade workers returned to the dashboard" "$missing_workers" ""
    [ "$SKIP_MINING_ASSERTS" = "1" ] || assert_num_ge "expected proxy workers resumed after upgrade" "$(jq_get "$after_state" '.proxy_workers')" "$EXPECTED_WORKERS"
    [ "$SKIP_MINING_ASSERTS" = "1" ] || assert_num_gt "stratum hashes resumed after upgrade" "$(jq_get "$after_state" '.stratum.total_hashes')" 0
    if telemetry_rows_continue "$before_telemetry" "$after_telemetry"; then
        it_pass "durable dashboard rows survived the image migration"
    else
        it_fail "durable dashboard rows survived the image migration" "one or more pre-upgrade rows or fixed-window aggregates changed"
    fi
    assert_telemetry_tables_present
    [ "$IT_FAIL" -le "$fails_before" ] || capture_artifacts "image-upgrade" "$OUT_DIR"
}
