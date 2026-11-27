#!/usr/bin/env bash

_image_upgrade_certificate_cleanup() {
    kill "$1" 2>/dev/null || true
    rm -rf "$2"
}

image_upgrade_certificate_continuity_leg() {
    local bundle tag srv srv_pid host_addr size aged verdict ip="" iface browser_work credentials
    have docker || {
        bad "image-upgrade certificate continuity requires Docker for the pinned browser runtime"
        return
    }
    info "image-upgrade certificate continuity — real dashboard update, reboot and original browser tab"
    if ! _vm_boot_disk "$IMAGE" || ! _wait_ssh 900; then
        bad "certificate-continuity guest never answered SSH"
        return
    fi
    _wizard_provision_capture 0 || {
        bad "certificate-continuity guest provisioning failed (${WIZ_FAIL_REASON:-unknown})"
        return
    }
    if ! provisioning_settled 900 || provisioning_setup_failed; then
        bad "certificate-continuity provisioning did not settle ($(provisioning_state))"
        return
    fi
    iface=$(_ssh "ip -4 route show default | awk '{for (i=1; i<=NF; i++) if (\$i == \"dev\") {print \$(i+1); exit}}'")
    [[ "$iface" =~ ^[a-zA-Z0-9_.-]+$ ]] || {
        bad "certificate-continuity guest route interface could not be identified"
        return
    }
    _ssh "ip -6 address replace fd00:2463::1/128 dev $iface && systemctl start pithead-address-watch.service" || {
        bad "certificate-continuity genuine SAN addition could not be staged"
        return
    }
    local san_ready=0 san_tries=0
    while [ "$san_tries" -lt 60 ]; do
        _ssh "systemctl start pithead-address-watch.service" >/dev/null 2>&1 || true
        if openssl s_client -connect "$ip:443" -servername "$ip" </dev/null 2>/dev/null |
            openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -qi 'FD00:2463'; then
            san_ready=1
            break
        fi
        sleep 5
        san_tries=$((san_tries + 1))
    done
    [ "$san_ready" -eq 1 ] || {
        bad "certificate-continuity genuine SAN addition never reached the served leaf"
        return
    }
    bundle=$(_build_bundle certificate-continuity) || {
        bundle_build_evidence
        bad "certificate-continuity candidate bundle build failed"
        return
    }
    tag="v$(tr -d ' \t\r\n' <VERSION)"
    srv=$(mktemp -d "${TMPDIR:?}/pithead-cert-update.XXXXXX") || {
        bad "certificate-continuity update server staging failed"
        return
    }
    cp "$bundle" "$srv/pithead-os-$tag.raucb"
    size=$(wc -c <"$srv/pithead-os-$tag.raucb" | tr -d ' ')
    printf '{"tag_name":"%s","html_url":"http://bench.invalid/rel","assets":[{"name":"pithead-os-%s.raucb","size":%s}]}' \
        "$tag" "$tag" "$size" >"$srv/releases-latest.json"
    host_addr=$(ip -4 -o addr show virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$host_addr" ] || host_addr="192.168.122.1"
    if ! srv_pid=$(_serve_update_dir "$srv" 8931); then
        bad "certificate-continuity update server did not start"
        rm -rf "$srv"
        return
    fi
    _ssh "printf 'http://$host_addr:8931' > /data/pithead/os-update-test-base" || {
        bad "certificate-continuity update feed could not be configured"
        _image_upgrade_certificate_cleanup "$srv_pid" "$srv"
        return
    }
    aged=$(aged_version "${tag#v}") || {
        bad "certificate-continuity running version could not be aged below ${tag#v}"
        _image_upgrade_certificate_cleanup "$srv_pid" "$srv"
        return
    }
    _ssh "printf '%s\n' '$aged' > /data/pithead/VERSION" || {
        bad "certificate-continuity running version could not be staged"
        _image_upgrade_certificate_cleanup "$srv_pid" "$srv"
        return
    }
    browser_work=$(mktemp -d "${TMPDIR:?}/pithead-cert-browser.XXXXXX") || {
        bad "certificate-continuity browser staging failed"
        _image_upgrade_certificate_cleanup "$srv_pid" "$srv"
        return
    }
    credentials=$(mktemp "${TMPDIR:?}/pithead-cert-credentials.XXXXXX") || {
        bad "certificate-continuity credential staging failed"
        _image_upgrade_certificate_cleanup "$srv_pid" "$srv"
        rm -rf "$browser_work"
        return
    }
    chmod 0600 "$credentials"
    cp "$SCRIPT_DIR/../../dashboard/tests/browser/package.json" \
        "$SCRIPT_DIR/../../dashboard/tests/browser/package-lock.json" \
        "$SCRIPT_DIR/image-upgrade-browser.mjs" \
        "$browser_work/"
    printf '%s\n%s' "$DASH_USER" "$DASH_PASS" |
        jq -Rs 'split("\n") | {username: .[0], password: .[1]}' >"$credentials"
    if verdict=$(python3 "$SCRIPT_DIR/image-upgrade-browser-host.py" \
        "https://$ip" "$KEY" "$browser_work" "$iface" <"$credentials" 2>&1); then
        ok "$verdict"
    else
        printf '     %s\n' "$verdict"
        bad "original browser tab did not retain certificate trust through the real update (${verdict:0:300})"
    fi
    rm -f "$credentials"
    rm -rf "$browser_work"
    _image_upgrade_certificate_cleanup "$srv_pid" "$srv"
}
