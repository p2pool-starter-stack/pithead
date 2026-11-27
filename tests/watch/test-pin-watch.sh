#!/usr/bin/env bash
# Offline regression cases for scripts/watch/pin-watch.sh --self-test.
# shellcheck disable=SC2034,SC2329 # Sourced by the watcher; stubs are called there.
st_fail=0
st() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then
        echo "  self-test ok: $1"
    else
        echo "  self-test FAIL: $1 (got [$2], want [$3])"
        st_fail=1
    fi
}
# The three spellings that would otherwise be reported stale every week for ever.
st "a bare image tag normalises to the upstream version" "$(norm 'caddy:2.11.4')" "2.11.4"
st "a leading v is not a version difference" "$(norm 'v6.26.0')" "6.26.0"
st "tari's network suffix is not a version difference" \
    "$(norm 'quay.io/tarilabs/minotari_node:v5.3.1-mainnet')" "5.3.1"
st "a digest suffix is not part of the version" \
    "$(norm 'caddy:2.11.4@sha256:aaaa')" "2.11.4"
# And the comparison must still SEE a real gap.
st "a real gap survives normalisation" \
    "$([ "$(norm 'v5.3.1-mainnet')" = "$(norm 'v5.6.0')" ] && echo same || echo differs)" "differs"
st "pinned prerelease is newer than older stable" "$(version_status v6.0.1-pre.0 v6.0.0)" ahead
st "same pinned version is current" "$(version_status v6.0.1-pre.0 v6.0.1-pre.0)" current
st "newer stable is ahead" "$(version_status v6.0.1-pre.0 v6.0.2)" stale
st "matching stable supersedes prerelease" "$(version_status v6.0.1-pre.0 v6.0.1)" stale
st "newer prerelease is ahead" "$(version_status v6.0.1-pre.0 v6.0.1-pre.1)" stale
st "numeric components beat text ordering" "$(version_order v6.0.9 v6.0.10)" older
st "prerelease numbers beat text ordering" "$(version_order v6.0.1-pre.9 v6.0.1-pre.10)" older
st "prerelease labels use precedence" "$(version_order v6.0.1-pre.9 v6.0.1-rc.0)" older
st "unrecognized version is unchecked" \
    "$(version_status v6.0.1-nightly v6.0.1 >/dev/null && echo accepted || echo refused)" refused
st "unreadable prerelease feed is unchecked" \
    "$(
        gh() { return 1; }
        newer_tari_prereleases v6.0.1-pre.0 >/dev/null && echo accepted || echo refused
    )" refused
st "unreadable feed marks report unchecked and increments failures" \
    "$(
        gh() { return 1; }
        failed=0 tari_prereleases=""
        add_tari_prerelease_report v6.0.1-pre.0
        printf '%s|%s' "$failed" "$tari_prereleases"
    )" \
    "1|**prerelease lookup failed — NOT checked**"
st "newer prereleases stay separate" \
    "$(
        gh() {
            [[ "$*" != *'prerelease == true'* ]] || return 1 # A prerelease-shaped Tari tag can have false metadata.
            printf '%s\n' v6.0.1-pre.1 v6.0.1-pre.0 v6.0.0-pre.0 v4.10.0
        }
        newer_tari_prereleases v6.0.1-pre.0
    )" v6.0.1-pre.1
st "no newer prerelease is a completed check" \
    "$(
        gh() { printf '%s\n' v6.0.1-pre.0; }
        newer_tari_prereleases v6.0.1-pre.0 >/dev/null && echo checked || echo failed
    )" checked
# UNREACHABLE MUST NOT READ AS CURRENT — the defect this whole script is aimed at.
st "a release lookup that cannot run fails" \
    "$(
        gh() { return 1; }
        latest_release foo/bar >/dev/null 2>&1 && echo ok || echo failed
    )" "failed"
st "a non-version tag is refused, not compared" \
    "$(
        gh() { printf 'nightly'; }
        latest_release foo/bar >/dev/null 2>&1 && echo ok || echo failed
    )" "failed"
st "a tag with report markup is refused" \
    "$(
        gh() { printf 'v6.0.0|bad'; }
        latest_release foo/bar >/dev/null 2>&1 && echo ok || echo failed
    )" failed
# A COMMIT pin cannot be compared against a TAG. What follows covers the resolution that
# makes the rigforge row honest, and the property the sha comparison rests on.
st "an upstream tag resolves to the commit it names" \
    "$(
        gh() { printf '%s' 4ce29b3daf063fd1b45e050649e93aa9592618e1; }
        comparable rigforge foo/bar v1.16.0
    )" "4ce29b3daf063fd1b45e050649e93aa9592618e1"
# The issue's own requirement: a resolution that cannot run reaches the unchecked row rather than
# any verdict at all. It is not uniquely load-bearing — see the overlap note on the next case but one.
st "a commit resolution that cannot run fails" \
    "$(
        gh() { return 1; }
        comparable rigforge foo/bar v1.16.0 >/dev/null 2>&1 && echo ok || echo failed
    )" "failed"
# The two refusals below overlap on every realistic input, and a mutation round proved it: with
# the `|| return 1` removed, this next case still failed — because an empty `sha` fails the shape
# check too, so the shape guard silently covered for the exit-code guard's deletion. Each is now
# pinned on the one input only IT refuses. This one is the exit code being trusted over stdout.
st "a resolution that exits non-zero is refused even when it printed a commit" \
    "$(
        gh() {
            printf '%s' 4ce29b3daf063fd1b45e050649e93aa9592618e1
            return 1
        }
        comparable rigforge foo/bar v1.16.0 >/dev/null 2>&1 && echo ok || echo failed
    )" "failed"
st "an answer that is not shaped like a commit is refused, not compared" \
    "$(
        gh() { printf 'Not Found'; }
        comparable rigforge foo/bar v1.16.0 >/dev/null 2>&1 && echo ok || echo failed
    )" "failed"
# And every version-spelled pin is still compared against the tag itself, unresolved.
st "a version pin is compared against the tag, with no lookup at all" \
    "$(comparable caddy caddyserver/caddy v2.11.4)" "v2.11.4"
# Both sides of that comparison go through norm(), so norm must leave a commit sha untouched.
st "normalisation leaves a commit sha alone" \
    "$(norm 60aa883901fc74ea39ed2f21962b8ba7f96d73ba)" "60aa883901fc74ea39ed2f21962b8ba7f96d73ba"
st "a Tari node pin, release or pre-release (#2604), selects the matching upstream proto tag" \
    "$(tari_proto_ref 'x:v6.0.0-mainnet@sha256:aaaa') $(tari_proto_ref 'x:v6.0.1-pre.0-mainnet@sha256:aaaa')" "v6.0.0 v6.0.1-pre.0"
st "a malformed Tari pin is refused" \
    "$(tari_proto_ref 'ghcr.io/tari-project/minotari_node:latest' >/dev/null 2>&1 && echo accepted || echo refused)" "refused"
run_buf() {
    case "$1" in
    build)
        [ "$2" = . ] && return "${ST_LOCAL_BUILD_RC:-0}"
        [ "$2" = "https://github.com/tari-project/tari.git#tag=v6.0.0,subdir=applications/minotari_app_grpc/proto" ] || return 3
        return "${ST_UPSTREAM_BUILD_RC:-0}"
        ;;
    breaking)
        [ "$2" = "https://github.com/tari-project/tari.git#tag=v6.0.0,subdir=applications/minotari_app_grpc/proto" ] && [ "$3" = --against ] && [ "$4" = . ] || return 3
        return "${ST_BUF_BREAKING_RC:-0}"
        ;;
    esac
}
tree_pin() { printf '%s' 'ghcr.io/tari-project/minotari_node:v6.0.0-mainnet@sha256:aaaa'; }
row() { ST_ROW="$*"; }
proto_report() {
    failed=0 stale=0 ST_ROW=""
    add_tari_proto_row
    printf '%s|%s|%s' "$failed" "$stale" "$ST_ROW"
}
ST_LOCAL_BUILD_RC=0 ST_UPSTREAM_BUILD_RC=0 ST_BUF_BREAKING_RC=0
st "matching Tari protos render current in the weekly report" "$(proto_report)" "0|0|tari gRPC schema \`f42e14d\` \`v6.0.0\` compatible"
ST_BUF_BREAKING_RC=100
st "a node-side deletion renders breaking drift" "$(proto_report)" "0|1|tari gRPC schema \`f42e14d\` \`v6.0.0\` **breaking drift**"
ST_BUF_BREAKING_RC=0
st "a node-side addition stays compatible" "$(proto_report)" "0|0|tari gRPC schema \`f42e14d\` \`v6.0.0\` compatible"
ST_BUF_BREAKING_RC=1
st "a failed comparison keeps its own unchecked report" "$(proto_report)" "1|0|tari gRPC schema \`f42e14d\` \`v6.0.0\` **schema comparison failed — NOT checked**"
ST_UPSTREAM_BUILD_RC=1 ST_BUF_BREAKING_RC=0
st "a failed upstream build renders unchecked in the weekly report" "$(proto_report)" "1|0|tari gRPC schema \`f42e14d\` \`v6.0.0\` **upstream schema fetch/build failed — NOT checked**"
ST_UPSTREAM_BUILD_RC=0 ST_LOCAL_BUILD_RC=100
st "a local parse failure keeps its own unchecked report" "$(proto_report)" "1|0|tari gRPC schema \`f42e14d\` \`v6.0.0\` **vendored schema build failed — NOT checked**"
st "the real weekly report invokes the Tari proto row" "$(grep -c '^add_tari_proto_row$' "$0")" "1"
integration_root=$(mktemp -d)
trap 'rm -rf "$integration_root"' EXIT
mkdir -p "$integration_root/os/rootfs" "$integration_root/scripts/watch"
: >"$integration_root/os/rootfs/Dockerfile"
printf '%s\n' 'printf "raise-watch-called\n"' 'exit 1' >"$integration_root/scripts/watch/go-raise-watch.sh"
ROOT=$integration_root
failed=0
finish_rc=0
finish_out=$(finish_report) || finish_rc=$?
st "a failed Go raise watch fails the combined report" "$finish_rc" "1"
st "the combined report actually ran the Go raise watch" "$(grep -c raise-watch-called <<<"$finish_out")" "1"
st "a failed Go raise watch withholds the last-success stamp" "$(grep -c 'Last fully successful' <<<"$finish_out")" "0"
ROOT="$integration_root/no-rootfs"
mkdir -p "$ROOT"
failed=1
finish_rc=0
finish_out=$(finish_report) || finish_rc=$?
st "an unchecked prerelease report fails the run" "$finish_rc" "1"
st "an unchecked prerelease report withholds the last-success stamp" "$(grep -c 'Last fully successful' <<<"$finish_out")" "0"
[ "$st_fail" = 0 ] && echo "pin-watch self-test OK"
exit "$st_fail"
