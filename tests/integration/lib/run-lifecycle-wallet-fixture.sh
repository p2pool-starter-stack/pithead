# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

# Create the wallet volume through the profile that owns it, then leave the
# inactive Compose model for uninstall. The unrelated volume pins its scope.
arm_inactive_tari_wallet_volume() {
    local volumes labels model compose_out
    if has_compose_profile "$(env_on_box COMPOSE_PROFILES)" tari_payout_confirm; then
        it_fail "Tari payout profile starts inactive" "tari_payout_confirm is active"
        return 1
    fi
    volumes="$(rx 'docker volume ls -q')" || {
        it_fail "wallet volume precondition readable" "volume listing failed"
        return 1
    }
    if printf '%s\n' "$volumes" | grep -Fx pithead_tari_wallet_db >/dev/null; then
        labels="$(rx "docker volume inspect pithead_tari_wallet_db --format '{{index .Labels \"com.docker.compose.project\"}}/{{index .Labels \"com.docker.compose.volume\"}}'")" || labels=""
        if [ "$labels" != 'pithead/tari_wallet_db' ]; then
            it_fail "preexisting Tari wallet volume is Compose-owned" "volume labels did not match"
            return 1
        fi
        if ! rx 'docker volume rm pithead_tari_wallet_db' >/dev/null 2>&1; then
            it_fail "preexisting owned wallet volume reset for Compose creation" "volume removal failed"
            return 1
        fi
        it_pass "preexisting owned wallet volume reset for Compose creation"
    fi
    if ! rx "sed -i '/^COMPOSE_PROFILES=/ s/$/,tari_payout_confirm/' .env" ||
        ! has_compose_profile "$(env_on_box COMPOSE_PROFILES)" tari_payout_confirm; then
        rx 'cp -p .env.itest-round-trip .env' >/dev/null 2>&1
        it_fail "active Compose profile creates the wallet volume" "profile activation failed"
        return 1
    fi
    IT_WALLET_CREATE_ATTEMPTED=1
    if ! compose_out="$(rx 'docker compose up --no-deps --no-start tari-wallet' 2>&1)"; then
        rx 'cp -p .env.itest-round-trip .env' >/dev/null 2>&1
        it_fail "active Compose profile creates the wallet volume" \
            "compose up --no-start failed: $(printf '%s\n' "$compose_out" | tail -n 15 | redact | LC_ALL=C tr -c '[:print:]' ' ' | tail -c 2000)"
        return 1
    fi
    labels="$(rx "docker volume inspect pithead_tari_wallet_db --format '{{index .Labels \"com.docker.compose.project\"}}/{{index .Labels \"com.docker.compose.volume\"}}'")" || labels=""
    if [ "$labels" != 'pithead/tari_wallet_db' ]; then
        it_fail "active Compose creates an owned Tari wallet volume" "Compose volume labels did not match"
        return 1
    fi
    it_pass "active Compose creates an owned Tari wallet volume"
    if ! rx 'docker compose rm -sf tari-wallet' >/dev/null 2>&1 ||
        ! rx 'cp -p .env.itest-round-trip .env' ||
        has_compose_profile "$(env_on_box COMPOSE_PROFILES)" tari_payout_confirm; then
        it_fail "Tari payout profile disabled before uninstall" "service removal or profile restoration failed"
        return 1
    fi
    model="$(rx 'docker compose config --volumes')" || {
        it_fail "inactive Compose model readable" "compose config failed"
        return 1
    }
    if printf '%s\n' "$model" | grep -Fx tari_wallet_db >/dev/null; then
        it_fail "inactive Compose model omits Tari wallet volume" "volume remains in the model"
        return 1
    fi
    it_pass "Tari payout profile disabled and wallet volume absent from Compose model"
    local nonce
    nonce="$(rx 'date +%s%N')"
    if [[ ! "$nonce" =~ ^[0-9]{15,}$ ]]; then
        it_fail "unrelated volume fixture has a unique name" "clock probe failed"
        return 1
    fi
    IT_UNRELATED_VOLUME_NAME="pithead_itest_unrelated_$nonce"
    if ! rx "docker volume create $(quote_arg "$IT_UNRELATED_VOLUME_NAME")" >/dev/null; then
        it_fail "unrelated volume fixture created" "volume creation failed"
        return 1
    fi
    IT_UNRELATED_VOLUME_CREATED=1
    it_pass "unrelated volume fixture created"
}

cleanup_failed_tari_wallet_fixture() {
    local labels="" containers="" volumes=""
    if [ -n "$IT_WALLET_CREATE_ATTEMPTED" ]; then
        containers="$(rx 'docker container ls -a --format "{{.Names}}"')" ||
            it_fail "failed fixture lists containers for cleanup" "Docker container listing failed"
        if printf '%s\n' "$containers" | grep -Fx tari-wallet >/dev/null &&
            ! rx 'docker compose --profile tari_payout_confirm rm -sf tari-wallet' >/dev/null 2>&1; then
            it_fail "failed fixture removes its wallet container" "Compose service cleanup failed"
        fi
        volumes="$(rx 'docker volume ls -q')" ||
            it_fail "failed fixture lists volumes for cleanup" "Docker volume listing failed"
        if printf '%s\n' "$volumes" | grep -Fx pithead_tari_wallet_db >/dev/null; then
            labels="$(rx "docker volume inspect pithead_tari_wallet_db --format '{{index .Labels \"com.docker.compose.project\"}}/{{index .Labels \"com.docker.compose.volume\"}}'")" ||
                it_fail "failed fixture inspects wallet volume for cleanup" "Docker volume inspection failed"
            if [ "$labels" = 'pithead/tari_wallet_db' ] &&
                ! rx 'docker volume rm pithead_tari_wallet_db' >/dev/null 2>&1; then
                it_fail "failed fixture removes its owned wallet volume" "volume cleanup failed"
            fi
        fi
    fi
    if [ -n "$IT_UNRELATED_VOLUME_CREATED" ] &&
        ! rx "docker volume rm $(quote_arg "$IT_UNRELATED_VOLUME_NAME")" >/dev/null 2>&1; then
        it_fail "failed fixture removes its unrelated volume" "volume cleanup failed"
    fi
}
