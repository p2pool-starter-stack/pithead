tor_lifecycle_receipt() {
    local operation="$1" action="$2" result="$3" identity
    [[ "$operation" =~ ^rotate-[0-9]{1,12}-[0-9]{1,12}$ ]] || operation=unavailable
    case "$action" in stop | up) ;; *) return 0 ;; esac
    [[ "$result" = requested || "$result" =~ ^[0-9]{1,3}$ ]] || return 0
    identity=$(timeout 2 docker inspect --format '{{.Id}}' tor 2>/dev/null | head -c 65) || identity=unavailable
    [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || identity=unavailable
    printf 'pithead-tor-lifecycle {"timestamp":"%s","caller":"onion-rotation","operation":"%s","container":"%s","action":"%s","result":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$operation" "$identity" "$action" "$result" >&2
}

tor_rotation_receipt() {
    if [ -n "${TOR_ROTATION_OPERATION:-}" ]; then
        tor_lifecycle_receipt "$TOR_ROTATION_OPERATION" "$1" "$2" || true
    fi
}
