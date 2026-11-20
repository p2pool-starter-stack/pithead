# shellcheck shell=bash
# shellcheck disable=SC2034

REALUPGRADE_REPO="p2pool-starter-stack/pithead"
REALUPGRADE_BOOT_GATE_S=900
REALUPGRADE_SOAK_S=600
REALUPGRADE_LEGS_DEFAULT="upgrade,soak,negctl"
REALUPGRADE_SEED_UNIT="pithead-realupgrade-seed.service"

realupgrade_old_tag() { # <tree-version> <tag>... ; greatest vX.Y.Z strictly below the tree version
    local ver="$1" t best=""
    shift
    for t in "$@"; do
        [[ "$t" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        [ "${t#v}" != "$ver" ] || continue
        [ "$(printf '%s\n%s\n' "${t#v}" "$ver" | sort -V | head -n1)" = "${t#v}" ] || continue
        if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "${best#v}" "${t#v}" | sort -V | tail -n1)" = "${t#v}" ]; then
            best="$t"
        fi
    done
    [ -n "$best" ] && printf '%s\n' "$best"
}

realupgrade_commit_budget_s() { # <boot-gate-timeout-s>; the gate timeout plus 50%
    [[ "$1" =~ ^[0-9]+$ ]] && printf '%s\n' $(($1 + $1 / 2))
}

realupgrade_legs_valid() { # <comma list>; soak needs the upgrade it follows
    local list="$1" leg seen=""
    [ -n "$list" ] || return 1
    local IFS=,
    for leg in $list; do
        case "$leg" in upgrade | soak | negctl) seen="$seen,$leg" ;; *) return 1 ;; esac
    done
    case "$seen" in *,soak*) case "$seen" in *,upgrade*) ;; *) return 1 ;; esac ;; esac
}

realupgrade_leg_enabled() { # <leg> <comma list>
    case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

realupgrade_stamp() { # <leg> <event>
    printf 'realupgrade-leg %s epoch=%s leg=%s event=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$1" "$2"
}

realupgrade_within_budget() { # <seconds-taken> <budget-s>
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]] && [ "$1" -le "$2" ]
}

realupgrade_verdict_updated() { # <os_update json>
    printf '%s' "$1" | jq -e '.verdict.outcome == "updated"' >/dev/null 2>&1
}

realupgrade_no_offer_while_verifying() { # <os_update json>; a verifying slot is never offered a reboot
    printf '%s' "$1" | jq -e '.step != "reboot-pending"' >/dev/null 2>&1
}

realupgrade_fingerprint_same() { # <before> <after>
    [ -n "$1" ] && [ "$1" = "$2" ]
}

realupgrade_sans_same() { # <before> <after>; order-insensitive
    [ -n "$1" ] && [ "$(printf '%s\n' "$1" | tr ',' '\n' | sort)" = "$(printf '%s\n' "$2" | tr ',' '\n' | sort)" ]
}

realupgrade_shares_grew() { # <before> <after>
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt "$1" ]
}

realupgrade_seed_script() {
    cat <<'SEED'
#!/bin/sh
set -eu
D=/data/pithead
i=0
while [ ! -x "$D/pithead" ] && [ "$i" -lt 3600 ]; do
    sleep 5
    i=$((i + 1))
done
[ -x "$D/pithead" ] || exit 1
for f in monero tari; do
    mkdir -p "$D/data/$f"
    [ -s "$D/data/$f/realupgrade-sentinel" ] || head -c 4096 /dev/urandom | base64 >"$D/data/$f/realupgrade-sentinel"
done
[ -s "$D/data/realupgrade-seed.json" ] || printf '{"monero":"%s","tari":"%s"}\n' \
    "$(sha256sum "$D/data/monero/realupgrade-sentinel" | cut -d' ' -f1)" \
    "$(sha256sum "$D/data/tari/realupgrade-sentinel" | cut -d' ' -f1)" >"$D/data/realupgrade-seed.json"
[ -s "$D/os-update-test-base" ] || printf '%s' "$(cat /etc/pithead-realupgrade-base)" >"$D/os-update-test-base"
chown root:root "$D/os-update-test-base"
SEED
}

realupgrade_seed_unit() {
    printf '[Unit]\nDescription=realupgrade harness seed\nAfter=data.mount\nRequiresMountsFor=/data\n\n[Service]\nType=simple\nExecStart=/usr/local/sbin/pithead-realupgrade-seed\n\n[Install]\nWantedBy=multi-user.target\n'
}

realupgrade_patch_root() { # <root> <test-cert.pem> <base-url> <manifest-out>; adds trust, never replaces it
    local root="$1" cert="$2" base="$3" manifest="$4" ring="$1/etc/rauc/keyring.pem" before after
    [ -s "$ring" ] && [ -s "$cert" ] && [ -d "$root/etc/systemd/system" ] || return 1
    before=$(grep -c 'BEGIN CERTIFICATE' "$ring")
    [ "$before" -ge 1 ] || return 1
    [ -z "$(tail -c1 "$ring")" ] || printf '\n' >>"$ring"
    cat "$cert" >>"$ring"
    after=$(grep -c 'BEGIN CERTIFICATE' "$ring")
    [ "$after" -gt "$before" ] || return 1
    mkdir -p "$root/usr/local/sbin" "$root/etc/systemd/system/multi-user.target.wants"
    realupgrade_seed_script >"$root/usr/local/sbin/pithead-realupgrade-seed"
    chmod 0755 "$root/usr/local/sbin/pithead-realupgrade-seed"
    realupgrade_seed_unit >"$root/etc/systemd/system/$REALUPGRADE_SEED_UNIT"
    ln -sf "../$REALUPGRADE_SEED_UNIT" "$root/etc/systemd/system/multi-user.target.wants/$REALUPGRADE_SEED_UNIT"
    printf '%s' "$base" >"$root/etc/pithead-realupgrade-base"
    jq -nc --argjson before "$before" --argjson after "$after" '{
        planted: ["/etc/rauc/keyring.pem", "/usr/local/sbin/pithead-realupgrade-seed",
            "/etc/systemd/system/'"$REALUPGRADE_SEED_UNIT"'",
            "/etc/systemd/system/multi-user.target.wants/'"$REALUPGRADE_SEED_UNIT"'", "/etc/pithead-realupgrade-base"],
        keyring_certs_before: $before, keyring_certs_after: $after}' >"$manifest"
}

realupgrade_attach_and_patch() { # <image> <test-cert.pem> <base-url> <manifest-out>
    local img="$1" loop mnt tries=0 rc=0 fstype
    loop=$(losetup -Pf --show "$img") || return 1
    while [ ! -e "${loop}p2" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    [ -e "${loop}p2" ] || {
        losetup -d "$loop"
        return 1
    }
    fstype=$(blkid -o value -s TYPE "${loop}p2" 2>/dev/null)
    printf 'realupgrade: slot-a filesystem type %s\n' "${fstype:-unknown}"
    mnt=$(mktemp -d) || {
        losetup -d "$loop"
        return 1
    }
    if mount "${loop}p2" "$mnt"; then
        realupgrade_patch_root "$mnt" "$2" "$3" "$4" || rc=1
        umount "$mnt" || rc=1
    else
        rc=1
    fi
    rmdir "$mnt"
    losetup -d "$loop"
    return "$rc"
}
