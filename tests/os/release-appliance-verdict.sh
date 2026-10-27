#!/usr/bin/env bash

release_appliance_verdict() {
    local image=$1 bundle=$2 keyring=${PITHEAD_RAUC_KEYRING:-${PITHEAD_RAUC_CERT:-os/rauc/certs/cert.pem}}
    local version commit scratch result=0
    version=$(tr -d '[:space:]' <VERSION)
    commit=$(git rev-parse HEAD)
    scratch=$(mktemp -d "${TMPDIR:-$PACKAGE_APPLIANCE_STAGE}/pithead-release-identity.XXXXXX") || return 1
    if TMPDIR="$scratch" bash scripts/release/appliance.sh --identity "$image" "$bundle" "$keyring" "$version" "$commit" debug >"$scratch/identity.log" 2>&1; then
        ok "release appliance verifier accepts the built image identity, baked RigForge and signed bundle (#1800)"
    else
        bash scripts/sanitize-test-log.sh "$scratch/identity.log"
        bad "release appliance identity or signature verification failed (#1800)"
        result=1
    fi
    head -c 128 "$bundle" >"$scratch/truncated.raucb" || result=1
    if TMPDIR="$scratch" bash scripts/release/appliance.sh --identity "$image" "$scratch/truncated.raucb" "$keyring" "$version" "$commit" debug >"$scratch/rejected.log" 2>&1; then
        bad "release appliance verifier accepted a truncated signed bundle (#1800)"
        result=1
    elif [ "$result" -eq 0 ]; then
        ok "release appliance verifier refuses a truncated signed bundle (#1800)"
    fi
    rm -r "$scratch" || result=1
    return "$result"
}
