# A late, Pithead-owned GRUB drop-in: grub-mkconfig sources the main defaults then
# grub.d/*.cfg, so editing only the defaults loses to Ubuntu's cloud console override.
# Put the reservation in GRUB_CMDLINE_LINUX, which also reaches recovery entries.
# Strip older reservations/THP typos from both variables without editing user files.
# Tokenize without executing shell text. Keep quoted argument values intact, and
# expose decoded tokens for parameter-name comparisons. Shared by the generated
# drop-in and the generated-entry verifier so they agree on argument boundaries.
grub_tokenizer_awk() {
    cat <<'AWK'
function parse(s,   i,c,q,raw,val,n) {
    for(i in word) delete word[i]
    for(i in value) delete value[i]
    q=""; raw=""; val=""; n=0
    for(i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if(c=="\\" && i<length(s)) {
            raw=raw c substr(s,++i,1); val=val substr(s,i,1)
        } else if(c==sprintf("%c",34) || c==sprintf("%c",39)) {
            raw=raw c
            if(q==c) q=""
            else if(q=="") q=c
            else val=val c
        } else if(c ~ /[[:space:]]/ && q=="") {
            if(raw!="") { word[++n]=raw; value[n]=val; raw=""; val="" }
        } else { raw=raw c; val=val c }
    }
    if(q!="") return -1
    if(raw!="") { word[++n]=raw; value[n]=val }
    return n
}
AWK
}

grub_hugepages_dropin_content() {
    cat <<'CFG' || return 1
# Managed by Pithead setup. Remove this file to stop reserving HugePages at boot.
# Keep all other arguments supplied by the main defaults and earlier drop-ins.
_pithead_grub_clean() {
    awk '
CFG
    grub_tokenizer_awk || return 1
    cat <<'CFG' || return 1
    {
        n=parse($0); if(n<0) exit 1
        sep=""
        for(i=1;i<=n;i++) {
            if(value[i] ~ /^(hugepagesz|hugepages|transparent_hugepages?)=/) continue
            printf "%s%s",sep,word[i]; sep=" "
        }
        printf "\n"
    }
    '
}
GRUB_CMDLINE_LINUX=$(printf '%s\n' "${GRUB_CMDLINE_LINUX:-}" | _pithead_grub_clean) || return 1
GRUB_CMDLINE_LINUX_DEFAULT=$(printf '%s\n' "${GRUB_CMDLINE_LINUX_DEFAULT:-}" | _pithead_grub_clean) || return 1
unset -f _pithead_grub_clean
CFG
    printf 'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} %s"\n' "$(randomx_boot_params)" || return 1
}

write_grub_hugepages() {
    local grub="$1" tmp dropin="$1.d/zz-pithead-hugepages.cfg"
    GRUB_HUGEPAGES_CHANGED=false
    tmp=$(mktemp) || return 1
    if ! grub_hugepages_dropin_content >"$tmp" || ! sudo mkdir -p "$grub.d"; then
        rm -f "$tmp"
        return 1
    fi
    if ! sudo cmp -s "$tmp" "$dropin"; then
        if ! sudo install -m 0644 "$tmp" "$dropin"; then
            rm -f "$tmp"
            return 1
        fi
        GRUB_HUGEPAGES_CHANGED=true
    fi
    rm -f "$tmp"
}

# update-grub's exit status alone is insufficient. Check this host's generated
# Linux section, including recovery entries; memory tests and os-prober entries
# do not consume this host's defaults. No readable host kernel entries is failure.
grub_host_kernel_entries() {
    sudo cat "${PITHEAD_GRUB_CONFIG:-/boot/grub/grub.cfg}" | awk '
        /^### BEGIN / { host=($0 ~ /\/(10_linux|10_linux_zfs|20_linux_xen) ###$/); next }
        /^### END / { host=0; next }
        host && $1 ~ /^(linux|linuxefi|linux16)$/ { print }
    '
}

verify_grub_hugepages() {
    grub_host_kernel_entries | grub_hugepages_entries_valid
}

verify_running_grub_hugepages() {
    local cmdline
    cmdline=$(cat "${PITHEAD_CMDLINE:-/proc/cmdline}") || return 1
    printf 'linux /running %s\n' "$cmdline" | grub_hugepages_entries_valid
}

grub_hugepages_entries_valid() {
    awk -v pages="$PITHEAD_HUGEPAGES" "$(grub_tokenizer_awk)"'
        $1 ~ /^(linux|linuxefi|linux16)$/ {
            entries++; size=0; count=0; thp=0
            n=parse($0); if(n<0) { bad=1; next }
            for (i=3; i<=n; i++) {
                if (value[i] == "hugepagesz=2M") size++
                else if (value[i] ~ /^hugepagesz=/) bad=1
                if (value[i] == "hugepages=" pages) count++
                else if (value[i] ~ /^hugepages=/) bad=1
                if (value[i] == "transparent_hugepage=never") thp++
                else if (value[i] ~ /^transparent_hugepages?=/) bad=1
            }
            if (size != 1 || count != 1 || thp != 1) bad=1
        }
        END { exit (!entries || bad) }
    '
}

persist_grub_hugepages() {
    local grub="$1" before
    before=$(grub_host_kernel_entries 2>/dev/null) || before=""
    if ! write_grub_hugepages "$grub"; then
        warn "Could not write Pithead's HugePages GRUB drop-in. Persistent HugePages setup failed."
        return 1
    fi
    if ! command -v update-grub >/dev/null || ! sudo update-grub; then
        warn "Persistent HugePages setup failed: run 'sudo update-grub' after fixing the bootloader configuration."
        return 1
    fi
    if ! verify_grub_hugepages; then
        warn "Persistent HugePages setup failed: generated GRUB kernel entries lack the requested parameters or contain conflicting values."
        warn "Check later GRUB drop-ins and /boot/grub/grub.cfg, then re-run setup. Do not reboot until the boot entries are correct."
        return 1
    fi
    if [ "$GRUB_HUGEPAGES_CHANGED" = true ] ||
        [ "$before" != "$(grub_host_kernel_entries)" ] || ! verify_running_grub_hugepages; then
        REBOOT_REQUIRED=true
        log "Verified persistent HugePages in generated GRUB kernel entries; reboot required."
    else
        log "Persistent HugePages already configured and verified."
    fi
}
