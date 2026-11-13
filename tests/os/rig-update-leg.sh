# shellcheck shell=bash
rig_update_leg() { # #4013: the rig fetches, verifies, installs and reports its own OS update
    info "rig-update leg — channel check, refusals, install and verdict through pithead rig-update"
    local tag srv host_addr port=8933 size srv_pid bundle out aged before marker
    tag="v$(tr -d ' \t\r\n' <VERSION)"
    if ! bundle=$(_build_bundle v3); then
        bundle_build_evidence
        bad "rig-update leg: v3 bundle build failed — read /tmp/os-fault-bundle.log"
        return
    fi
    srv=$(mktemp -d)
    cp "$bundle" "$srv/pithead-os-$tag.raucb"
    size=$(wc -c <"$srv/pithead-os-$tag.raucb" | tr -d ' ')
    printf '{"tag_name":"%s","html_url":"http://bench.invalid/rel","assets":[{"name":"pithead-os-%s.raucb","size":%s}]}' \
        "$tag" "$tag" "$size" >"$srv/releases-latest.json"
    host_addr=$(ip -4 -o addr show virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$host_addr" ] || host_addr="192.168.122.1"
    if ! srv_pid=$(_serve_update_dir "$srv" "$port"); then
        bad "rig-update leg: the bench release server never answered on :$port — this is the harness, not the product"
        rm -rf "$srv"
        return
    fi
    _ssh "printf 'http://$host_addr:$port' > /data/pithead/os-update-test-base" || {
        bad "rig-update leg: could not plant the update-server seam on the rig"
        kill "$srv_pid" 2>/dev/null || true
        rm -rf "$srv"
        return
    }
    if ! aged=$(aged_version "${tag#v}"); then
        bad "rig-update leg: cannot age the running version ${tag#v} (tests/os/aged-version.sh)"
        kill "$srv_pid" 2>/dev/null || true
        rm -rf "$srv"
        return
    fi
    _ssh "printf '%s\n' '$aged' > /data/pithead/VERSION" || {
        bad "rig-update leg: could not age the rig's running version to $aged"
        kill "$srv_pid" 2>/dev/null || true
        rm -rf "$srv"
        return
    }

    out=$(_ssh "cd /data/pithead && ./pithead rig-update check" 2>&1)
    case "$out" in
    *"running v$aged, release channel offers $tag"*)
        ok "rig-update check reports the running and published versions without installing"
        ;;
    *) bad "rig-update check did not report the seam release (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200))" ;;
    esac
    [ -z "$(_ssh 'pgrep -x tor 2>/dev/null' | tr -d '\r')" ] &&
        ok "the seam check started no Tor" || bad "the seam check started Tor"

    out=$(_ssh "cd /data/pithead && ./pithead rig-update install --max-version 2.0.0" 2>&1)
    case "$out" in
    *"above --max-version"*)
        ok "rig-update refuses the published tag above --max-version, semantically"
        ;;
    *) bad "the --max-version ceiling did not refuse (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200))" ;;
    esac
    if _rig_mining_up 6; then
        ok "the refusal left the rig mining"
    else
        bad "the rig stopped mining after a refusal"
    fi
    [ "$(_ssh "jq -r '.state' /data/pithead/rig-update.json" 2>/dev/null | tr -d '\r')" = "refused" ] &&
        ok "the refusal is recorded with its reason in rig-update.json" ||
        bad "the refusal did not reach the status file"

    _ssh "printf '{\"state\":\"pending\",\"from\":\"0.0.0\",\"to\":\"9.9.9\",\"ts\":1}' > /data/pithead/rig-update.json"
    out=$(_ssh "cd /data/pithead && ./pithead rig-update install" 2>&1)
    case "$out" in
    *"pending a reboot"*) ok "a pending update blocks a new install until the reboot settles it" ;;
    *) bad "the pending record did not refuse a second install (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200))" ;;
    esac
    [ "$(_ssh "jq -r '.to' /data/pithead/rig-update.json" 2>/dev/null | tr -d '\r')" = "9.9.9" ] &&
        ok "the refusal kept the pending record intact" || bad "the refusal clobbered the pending record"

    if ! before=$(_boot_id); then
        bad "rig-update leg: could not read the boot id before the install reboot — a reconnect and a reboot would look alike"
        kill "$srv_pid" 2>/dev/null || true
        rm -rf "$srv"
        return
    fi
    out=$(_ssh "cd /data/pithead && ./pithead rig-update install" 2>&1) || true
    if ! _wait_new_boot "$before" 420; then
        bad "rig-update leg: the rig never returned after rig-update installed the spare slot"
        kill "$srv_pid" 2>/dev/null || true
        rm -rf "$srv"
        return
    fi
    marker=$(_ssh cat /etc/pithead-test-marker | tr -d '\r\n')
    [ "$marker" = "v3" ] && ok "rig-update installed its bundle and the rig booted it" ||
        bad "expected v3 after rig-update's reboot, got '$marker'"
    _rig_mining_up 24 && ok "the rig mines again after the rig-update reboot" ||
        bad "the rig stopped mining after the rig-update reboot"
    [ "$(_ssh "jq -r '.state' /data/pithead/rig-update.json" 2>/dev/null | tr -d '\r')" = "updated" ] &&
        ok "the boot settled the verdict as updated in rig-update.json" ||
        bad "the post-boot verdict never landed in rig-update.json"
    _ssh "journalctl -u pithead-boot -b 2>/dev/null | grep -q 'verdict updated'" &&
        ok "pithead-boot's journal carries the updated verdict" ||
        bad "pithead-boot's journal has no verdict line"
    ! _ssh 'ls /data/pithead/data/os-update/pithead-os-* >/dev/null 2>&1' &&
        ok "the bundle and any partial were deleted after the install" ||
        bad "a staged bundle survived the rig-update outcome"

    out=$(_ssh "rm -f /data/pithead/os-update-test-base && cd /data/pithead && PITHEAD_TOR_TIMEOUT=300 ./pithead rig-update check" 2>&1)
    case "$out" in
    *"release channel offers v"*) ok "rig-update check reads the real release channel over Tor" ;;
    *) bad "the Tor check did not report the channel (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200))" ;;
    esac
    [ -z "$(_ssh 'pgrep -x tor 2>/dev/null' | tr -d '\r')" ] &&
        ok "Tor stopped after the check" || bad "Tor kept running after the check"

    _ssh 'rm -f /data/pithead/VERSION'
    kill "$srv_pid" 2>/dev/null || true
    rm -rf "$srv"
}
