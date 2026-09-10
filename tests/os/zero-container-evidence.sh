#!/usr/bin/env bash
# Evidence for the one defect five battery legs report and none of them captured (#2043):
# provisioning finishes, the dashboard login is published, and `compose up` creates NO containers.
# Sourced by tests/os/run.sh; uses its _ssh and its indentation idiom. Kept out of
# failure-evidence.sh so that file's ceiling is not the reason this dump has to be small.
#
# Every prior occurrence recycled the guest before anyone could ask it anything, so the issue's
# own first step is this dump. It is built around ONE discriminator: the pair of image lists.
# os/build-image.sh bakes a single archive — the wizard's dashboard image — so every other
# service is a PULL, and a ref the guest cannot resolve is a silent zero-container `up`.
#
#   comm -23 want have  non-empty -> the refs were missing; the substitution inputs below say
#                                    which half (registry or tag) produced the wrong ref.
#                       empty     -> the refs were all present and something else refused:
#                                    the cosign gate, the mutation lock, or a profile that
#                                    selected no services. The journal tail names which.
#
# The comparison is written to files on the guest rather than compared with process substitution:
# the remote shell is not guaranteed to be bash, and /tmp is the only writable place on the
# appliance's read-only rootfs. Journal lines naming a credential are dropped — this dump lands
# in a log a human reads.
stack_never_up_evidence() {
    printf '     --- guest evidence (#2043) ---\n'
    _ssh "cd /data/pithead 2>/dev/null || { echo 'NO /data/pithead — the program tree never synced'; exit 0; }
          echo '-- containers, including exited (a created-then-died stack is NOT zero) --'
          podman ps -a --format '{{.Names}} {{.Status}} {{.Image}}' 2>&1 | head -20
          docker compose config --images 2>/dev/null | sort -u >/tmp/2043-want
          podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u >/tmp/2043-have
          echo '-- refs compose WANTS that podman does NOT have (empty = not an image problem) --'
          comm -23 /tmp/2043-want /tmp/2043-have
          echo '-- what compose resolves --'; head -20 /tmp/2043-want
          echo '-- what podman has --'; head -30 /tmp/2043-have
          echo '-- substitution inputs --'
          grep -hE '^(PITHEAD_REGISTRY|STACK_VERSION|COMPOSE_PROFILES|COMPOSE_FILE)=' .env 2>/dev/null
          echo '-- registry the provisioning units see (the drop-in, not /etc/environment) --'
          systemctl show -p Environment pithead-boot.service pithead-firstboot.service 2>/dev/null
          echo '-- why up refused --'
          journalctl -u pithead-boot -u pithead-firstboot --no-pager -n 40 2>/dev/null |
              grep -viE 'password|token|secret|cosign.key'
          echo '-- failed units --'; systemctl --failed --no-legend 2>&1 | head -10
          echo '-- wizard spool --'; head -5 data/firstboot/error.txt 2>/dev/null" |
        tr -d '\r' | sed 's/^/     | /'
}

# --- self-test (#2043): no guest, no network ---------------------------------------------------
#
# The dump is one fire-and-forget _ssh call, so the only handle tier 1 has on it is what it ASKED.
# That is recorded to a FILE and not a variable: the dump pipes _ssh into tr/sed, and every
# pipeline element runs in a subshell, so an assignment inside the stub would die with it.
#
# What is pinned is the probe SET, because the leg is worthless if it loses the image comparison —
# the single question that tells a missing-ref defect apart from a refusal with every ref present.
_zc_rc=0
_zc_case() { # <label> <substring the asked command must contain>
    case "$(cat "$_zc_ask" 2>/dev/null)" in
    *"$2"*) printf 'ok: %s\n' "$1" ;;
    *)
        printf 'FAIL: %s — the #2043 dump never asked for: %s\n' "$1" "$2"
        _zc_rc=1
        ;;
    esac
}

_zc_self_test() {
    local out
    _zc_ask=$(mktemp)
    out=$(mktemp)
    _ssh() {
        printf '%s' "$*" >>"$_zc_ask"
        printf -- '-- containers, including exited (a created-then-died stack is NOT zero) --'
    }
    printf '== unit: the #2043 dump asks the discriminating questions ==\n'
    stack_never_up_evidence >"$out"
    _zc_case "it compares the refs compose wants against the refs podman has" "comm -23 /tmp/2043-want /tmp/2043-have"
    _zc_case "it reads the substitution inputs that produced those refs" "PITHEAD_REGISTRY|STACK_VERSION"
    _zc_case "it reads the registry the UNITS see, not /etc/environment" "systemctl show -p Environment"
    _zc_case "it shows exited containers, not just running ones" "podman ps -a"
    _zc_case "it captures why up refused" "journalctl -u pithead-boot"
    _zc_case "it keeps credentials out of the dump" "grep -viE 'password|token|secret"
    if grep -q '^     | -- containers' "$out"; then
        printf 'ok: the dump is prefixed so it reads inside the battery output\n'
    else
        printf 'FAIL: the #2043 dump is not prefixed, got: %s\n' "$(cat "$out")"
        _zc_rc=1
    fi
    rm -f "$_zc_ask" "$out"
    [ "$_zc_rc" -eq 0 ] || {
        printf '#2043 zero-container evidence self-test FAILED\n'
        return 1
    }
    printf '#2043 zero-container evidence self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--self-test" ]; then
    _zc_self_test
    exit $?
fi
