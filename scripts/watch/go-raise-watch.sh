#!/usr/bin/env bash
# Report whether each exact Go module raise in os/rootfs/Dockerfile still changes the pinned
# upstream module graph. Report-only: obsolete and downgrade findings are work to schedule, while
# an unreadable ARG or failed measurement makes the run fail as unchecked.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${DOCKERFILE:-$ROOT/os/rootfs/Dockerfile}"

arg() { sed -n "s/^ARG $1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$DOCKERFILE"; }

selected_version() { # <checkout> <module> -> selected version, or empty when absent
    GOTOOLCHAIN=local go -C "$1" list -m -f '{{.Path}}{{"\t"}}{{.Version}}' all |
        awk -F '\t' -v module="$2" '$1 == module { print $2 }'
}

classify_change() { # <module> <before> <after> <requested> <go-get-output> -> status<TAB>detail
    local module="$1" before="$2" after="$3" requested="$4" change="$5" detail
    [ "$after" = "$requested" ] || return 1
    if [ "$before" = "$after" ]; then
        printf 'obsolete\talready selected at %s without this entry\n' "$after"
    elif detail=$(printf "%s\n" "$change" | grep -Fx "go: upgraded $module $before => $after" | head -1); then
        printf 'active\t%s\n' "$detail"
    elif [ -z "$before" ] && detail=$(printf "%s\n" "$change" | grep -Fx "go: added $module $after" | head -1); then
        printf 'active\t%s\n' "$detail"
    elif detail=$(printf "%s\n" "$change" | grep -Fx "go: downgraded $module $before => $after" | head -1); then
        printf 'downgrade\t%s\n' "$detail"
    else
        return 1
    fi
}

measure_checkout() { # <checkout> <raise...> -> raise<TAB>active|obsolete|downgrade<TAB>detail
    local checkout="$1" candidate module requested before after change verdict spec
    local -a others
    shift
    for candidate in "$@"; do
        module=${candidate%@*}
        git -C "$checkout" reset -q --hard HEAD
        git -C "$checkout" clean -fdq
        others=()
        for spec in "$@"; do [ "$spec" = "$candidate" ] || others+=("$spec"); done
        if ((${#others[@]} > 0)) && ! GOTOOLCHAIN=local go -C "$checkout" get "${others[@]}" >/dev/null 2>&1; then return 1; fi
        if ! before=$(selected_version "$checkout" "$module"); then return 1; fi
        if ! change=$(GOTOOLCHAIN=local go -C "$checkout" get "$candidate" 2>&1); then return 1; fi
        if ! after=$(selected_version "$checkout" "$module"); then return 1; fi
        requested=${candidate##*@}
        verdict=$(classify_change "$module" "$before" "$after" "$requested" "$change") || return 1
        printf "%s\t%s\n" "$candidate" "$verdict"
    done
}

measure_project() { # <repo> <commit> <raise...> -> raise<TAB>active|obsolete|downgrade<TAB>detail
    local repo="$1" commit="$2" image spec
    shift 2
    image="$(sed -n 's/^FROM \(golang:[^ ]*@sha256:[0-9a-f]\{64\}\) AS gobuild$/\1/p' "$DOCKERFILE")"
    case "$repo" in docker/compose | sigstore/cosign) ;; *) return 1 ;; esac
    [ -n "$image" ] && [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    (($#)) || return 1
    for spec in "$@"; do [[ "$spec" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*@v[0-9][A-Za-z0-9.+-]*$ ]] || return 1; done

    docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges \
        --tmpfs /tmp:exec,size=2g -e HOME=/tmp/home -e GOPATH=/tmp/go \
        -v "${BASH_SOURCE[0]}:/go-raise-watch.sh:ro" "$image" \
        bash -ceu '
            repo=$1; commit=$2; shift 2
            git clone -q --filter=blob:none --no-checkout "https://github.com/$repo" /tmp/src
            git -C /tmp/src checkout -q --detach "$commit"
            exec bash /go-raise-watch.sh --measure-checkout /tmp/src "$@"
        ' _ "$repo" "$commit" "$@"
}

if [ "${1:-}" = "--measure-checkout" ]; then
    shift
    measure_checkout "$@"
    exit
fi

report() {
    local lane prefix repo commit raises output spec status detail expected actual rows="" failed=0 obsolete=0 downgrade=0 checked=0
    local -a raise_args
    for lane in compose cosign; do
        case "$lane" in
        compose)
            prefix=COMPOSE
            repo=docker/compose
            ;;
        cosign)
            prefix=COSIGN
            repo=sigstore/cosign
            ;;
        esac
        commit="$(arg "${prefix}_COMMIT")"
        raises="$(arg "${prefix}_GO_RAISES")"
        read -r -a raise_args <<<"$raises"
        if [ -z "$commit" ] || ((${#raise_args[@]} == 0)) || ! output=$(measure_project "$repo" "$commit" "${raise_args[@]}"); then
            rows+="| $lane | — | **UNCHECKED — could not resolve the pinned module graph** |"$'\n'
            failed=$((failed + 1))
            continue
        fi
        expected="$(printf '%s\n' "${raise_args[@]}" | sort)"
        actual="$(cut -f1 <<<"$output" | sort)"
        if [ "$actual" != "$expected" ]; then
            rows+="| $lane | — | **UNCHECKED — measurement did not return each declared raise exactly once** |"$'\n'
            failed=$((failed + 1))
            continue
        fi
        while IFS=$'\t' read -r spec status detail; do
            [ -n "$spec" ] || continue
            checked=$((checked + 1))
            case "$status" in
            active) verdict="active — $detail" ;;
            obsolete)
                verdict="**OBSOLETE — $detail**"
                obsolete=$((obsolete + 1))
                ;;
            downgrade)
                verdict="**INVALID — $detail**"
                downgrade=$((downgrade + 1))
                ;;
            *)
                failed=$((failed + 1))
                verdict="**UNCHECKED — malformed measurement**"
                ;;
            esac
            rows+="| $lane | \`$spec\` | $verdict |"$'\n'
        done <<<"$output"
    done

    # shellcheck disable=SC2016 # Markdown backticks, not shell expansion.
    printf '%s\n\n' 'Exact Go module raises in `os/rootfs/Dockerfile` (#1655). Report-only — a redundant pin is housekeeping, not a build failure.'
    printf '| binary | exact raise | verdict |\n|---|---|---|\n%s' "$rows"
    printf '\n%s\n' 'The weekly rootfs CVE scan checks whether a raised version has acquired a fixable HIGH or CRITICAL finding; this table checks the other arm, whether removing one entry leaves the resolved graph unchanged.'
    printf '\n<!-- go-raise-watch: obsolete=%s downgrade=%s checked=%s failed=%s -->\n' "$obsolete" "$downgrade" "$checked" "$failed"
    [ "$failed" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st() { [ "$2" = "$3" ] || {
        echo "self-test FAIL: $1 (got [$2], want [$3])"
        st_fail=1
    }; }
    fixture=$(mktemp)
    graph=$(mktemp -d)
    trap 'rm -f "$fixture"; rm -rf "$graph"' EXIT
    cat >"$fixture" <<'EOF'
FROM golang:1.26.8-trixie@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa AS gobuild
ARG COMPOSE_COMMIT=1111111111111111111111111111111111111111
ARG COSIGN_COMMIT=2222222222222222222222222222222222222222
ARG COMPOSE_GO_RAISES="example.test/active@v1.2.0 example.test/noop@v1.2.0"
ARG COSIGN_GO_RAISES="example.test/down@v1.0.0"
EOF
    DOCKERFILE="$fixture"
    mkdir -p "$graph/active-old" "$graph/active-new" "$graph/noop" "$graph/down"
    printf 'module example.test/active\n\ngo 1.21\n\nrequire example.test/noop v1.1.0\n' >"$graph/active-old/go.mod"
    printf 'module example.test/active\n\ngo 1.21\n\nrequire example.test/noop v1.2.0\n' >"$graph/active-new/go.mod"
    for module in noop down; do
        printf 'module example.test/%s\n\ngo 1.21\n' "$module" >"$graph/$module/go.mod"
    done
    cat >"$graph/go.mod" <<EOF
module fixture.test/watch

go 1.21

require (
	example.test/active v1.1.0
	example.test/down v1.2.0
)

replace example.test/active v1.1.0 => ./active-old
replace example.test/active v1.2.0 => ./active-new
replace example.test/noop => ./noop
replace example.test/down => ./down
EOF
    git -C "$graph" init -q
    git -C "$graph" add .
    git -C "$graph" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
    measured=$(measure_checkout "$graph" \
        example.test/active@v1.2.0 example.test/noop@v1.2.0 example.test/down@v1.0.0)
    measure_project() {
        case "$1" in
        docker/compose) printf '%s\n' "$measured" | sed -n '1,2p' ;;
        sigstore/cosign) printf '%s\n' "$measured" | sed -n '3p' ;;
        esac
    }
    out=$(report)
    st 'an active raise stays active' "$(grep -c 'active — go: upgraded' <<<"$out")" 1
    st 'a synthetic no-op raise is reported obsolete' "$(grep -c 'no-op\|OBSOLETE — already selected' <<<"$out")" 1
    st 'a downgrade is never called an active raise' "$(grep -c 'INVALID — go: downgraded' <<<"$out")" 1
    unknown_rc=0
    classify_change example.test/active v1.1.0 v1.2.0 v1.2.0 'unrecognized successful output' >/dev/null || unknown_rc=$?
    st 'an unrecognized successful mutation is unchecked' "$unknown_rc" 1
    prefixed_rc=0
    classify_change example.test/active v2.0.0 v1.0.0 v1.0.0 \
        'go: module example.test/active is deprecated: go: upgraded example.test/active v2.0.0 => v1.0.0' \
        >/dev/null || prefixed_rc=$?
    st 'a wrapped upgrade diagnostic cannot conceal a downgrade' "$prefixed_rc" 1
    st 'the trailer distinguishes findings from failed measurements' \
        "$(grep -o 'obsolete=[0-9]* downgrade=[0-9]* checked=[0-9]* failed=[0-9]*' <<<"$out")" \
        'obsolete=1 downgrade=1 checked=3 failed=0'
    measure_project() { return 1; }
    broken_rc=0
    broken=$(report) || broken_rc=$?
    st 'a failed resolved-graph measurement makes the report fail' "$broken_rc" 1
    st 'and names both projects unchecked rather than current' "$(grep -c 'UNCHECKED' <<<"$broken")" 2
    [ "$st_fail" -eq 0 ] && echo 'go-raise-watch self-test OK'
    exit "$st_fail"
fi

report
