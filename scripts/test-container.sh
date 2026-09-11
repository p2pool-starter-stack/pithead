#!/usr/bin/env bash
# test-container.sh — run the suite in the Linux image CI runs, from any host (#2078).
#
#   scripts/test-container.sh                 # make test
#   scripts/test-container.sh make test-stack # any target, or any command
#   scripts/test-container.sh --build         # force an image rebuild first
#   scripts/test-container.sh --ssh <cmd>     # also mount ~/.ssh (tier 4 only)
#
# Why this exists: #2041 made the shell suite refuse on macOS, because a failure there is not
# evidence — unmodified develop scored 3708 passed / 148 failed, and a shimmed `grep` returned 0
# matches for a pattern the true count of which was 53. This gives back a verdict that means
# something, without asking anyone to keep a Linux VM.
#
# NOT a CI change. Every GitHub-hosted job is already ubuntu-latest; this is the local loop.
set -uo pipefail

IMAGE=pithead-test-runner:local
# A named volume so uv and npx download once per machine rather than once per run. It PERSISTS
# across runs, which is the point and also the caveat: anything a compromised test dependency
# writes to $HOME (an .npmrc, a poisoned cache) outlives the run that wrote it. `docker volume rm
# pithead-test-home` is the reset.
HOME_VOLUME=pithead-test-home
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
ENGINE="${PITHEAD_TEST_ENGINE:-docker}"

# Does the git common dir need its own mount? True only when it lives OUTSIDE the repo mount,
# which is exactly the worktree case. Extracted so --self-test can hit it without docker.
needs_git_mount() {
    local root="$1" common="$2"
    case "$common" in
    "" | "$root" | "$root"/*) return 1 ;;
    *) return 0 ;;
    esac
}

if [ "${1:-}" = "--self-test" ]; then
    fails=0
    check() { # check <expect 0|1> <root> <common> <label>
        needs_git_mount "$2" "$3"
        local got=$?
        if [ "$got" = "$1" ]; then echo "  ok   $4"; else
            echo "  FAIL $4 (wanted rc $1, got $got)" >&2
            fails=$((fails + 1))
        fi
    }
    echo "test-container --self-test: the git-common-dir mount decision"
    check 1 /repo /repo/.git "a plain clone needs no extra mount"
    check 1 /repo /repo "a common dir equal to the root needs no extra mount"
    check 1 /repo "" "an unreadable/absent common dir adds nothing"
    check 0 /repo/.claude/worktrees/wt /repo/.git "a worktree mounts the common dir it points at"
    check 0 /a/wt /b/.git "an unrelated common dir is mounted"
    # The near miss: a sibling whose path merely SHARES the prefix is outside the mount, so the
    # prefix test has to be anchored at a separator. /repo-other is not inside /repo.
    check 0 /repo /repo-other/.git "a path sharing the root's prefix is still outside it"
    [ "$fails" -eq 0 ] || {
        echo "test-container --self-test: $fails FAILED" >&2
        exit 1
    }
    echo "test-container --self-test: all checks passed"
    exit 0
fi

command -v "$ENGINE" >/dev/null 2>&1 || {
    echo "test-container: '$ENGINE' not found — this needs a container engine on the host." >&2
    echo "  Install Docker Desktop (macOS/Windows) or docker.io (Linux), then re-run." >&2
    exit 1
}
"$ENGINE" info >/dev/null 2>&1 || {
    echo "test-container: '$ENGINE' is installed but its daemon is not answering." >&2
    echo "  Start Docker and re-run. Refusing rather than skipping: a suite that skips reads green." >&2
    exit 1
}

# `lint-sh` is the memory peak of the whole suite (#1206) and it dies as a bare "Killed" with
# rc 137 — no message, nothing naming memory, the shellcheck line just stops. Two measurements:
# against a 3.8 GiB engine shellcheck reached 3.45 GiB and was OOM-killed; given room, it PASSES
# and peaks at 7.20 GiB. So the bar is 8, not the 6 a partial reading first suggested. Warn rather
# than refuse: every other target needs a fraction of this, and blocking test-fakes over lint's
# ceiling would be its own kind of wrong.
LINT_PEAK_GIB=8
vm_bytes="$($ENGINE info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
if [ "${vm_bytes:-0}" -gt 0 ] && [ "$vm_bytes" -lt $((LINT_PEAK_GIB * 1024 * 1024 * 1024)) ]; then
    printf 'test-container: the engine has %.1f GiB; lint-sh peaks at 7.20 GiB given room, and is OOM-killed below 3.8.\n' \
        "$(awk -v b="$vm_bytes" 'BEGIN{print b/1073741824}')" >&2
    echo "  Targets other than lint run fine. For the full \`make test\`, raise the VM's memory to" >&2
    echo "  ${LINT_PEAK_GIB} GiB or more (Docker Desktop: Settings > Resources > Memory)." >&2
    echo "  A shortfall shows up as a bare 'Killed' and rc 137, which names nothing (#1206)." >&2
fi

BUILD=0
WANT_SSH=0
while :; do
    case "${1:-}" in
    --build)
        BUILD=1
        shift
        ;;
    --ssh)
        WANT_SSH=1
        shift
        ;;
    *) break ;;
    esac
done

# Build when asked, or when the image is not there yet. Not on every run: the layers are stable and
# a rebuild on each invocation is the difference between a 20-second loop and a 4-minute one.
if [ "$BUILD" -eq 1 ] || ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "test-container: building $IMAGE (first run pulls the toolchain; later runs reuse it)"
    # The Makefile is the single source for both pins (#1679, #1688) — read them, never retype them.
    "$ENGINE" build \
        --build-arg "SHELLCHECK_VERSION=$(make -s -C "$ROOT" print-shellcheck-version)" \
        --build-arg "SHFMT_VERSION=$(make -s -C "$ROOT" print-shfmt-version)" \
        --build-arg "PITHEAD_UID=$(id -u)" \
        --build-arg "PITHEAD_GID=$(id -g)" \
        -t "$IMAGE" "$ROOT/tests/runner" || exit 1
fi

# The repo is mounted at its OWN absolute path, not at /workspace. Several targets shell out to
# docker (lint-proto mounts "$PWD", mini-stack builds a compose context), and those mounts are
# resolved by the HOST daemon through the shared socket — a container-only path like /workspace
# does not exist there and the mount silently comes up empty. Same path on both sides, or nothing.
MOUNTS=(-v "$ROOT:$ROOT" -w "$ROOT")

# A git worktree's .git is a FILE pointing at an absolute path outside the worktree, and the lint
# targets lean on `git ls-files`. Without the common dir mounted, every one of them dies on a repo
# git cannot open. This repo's own workflow is worktree-heavy, so handle it rather than document it.
GIT_COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
needs_git_mount "$ROOT" "$GIT_COMMON" && MOUNTS+=(-v "$GIT_COMMON:$GIT_COMMON")

# Tier 4's live matrix ssh-es to a reserved box, so with --ssh the caller's keys reach the driver.
# OPT-IN, because this is a real credential exposure and the earlier "it adds no new trust boundary,
# the socket is already host-root-equivalent" was self-serving: pivoting through the socket means
# deliberately starting a privileged container, while a mounted ~/.ssh is one `cat` by any
# dependency the test tiers execute. Those are not the same reachability. Every other tier needs no
# ssh at all, so they no longer get the keys. Agent forwarding is not the answer here — it is empty
# on a host whose keys live in files, which is the case this has to work on.
if [ "$WANT_SSH" -eq 1 ]; then
    [ -d "$HOME/.ssh" ] && MOUNTS+=(-v "$HOME/.ssh:/home/pithead/.ssh:ro")
fi

# The socket is 0660 and the container user is deliberately not root, so the run needs the socket's
# GROUP — and which group that is differs by host, which is the part that bites. Docker Desktop
# presents it as root:root inside the container, so gid 0 is the answer there; a native Linux
# daemon owns it root:docker (988 on the bench), where gid 0 grants exactly NOTHING and every tier
# that shells out to docker dies on "permission denied ... unix:///var/run/docker.sock". Measured
# on both, because the macOS answer alone looks complete and is not. Pass both: on Linux the host's
# numeric gid is the one the container sees, and a gid the container has no use for is inert. This
# grants nothing the mount has not — reaching the host daemon is host-root-equivalent by itself.
SOCK=/var/run/docker.sock
SOCK_GIDS=()
if [ -S "$SOCK" ]; then
    MOUNTS+=(-v "$SOCK:$SOCK")
    SOCK_GIDS+=(0)
    sock_gid="$(stat -c %g "$SOCK" 2>/dev/null || stat -f %g "$SOCK" 2>/dev/null || true)"
    [ -n "$sock_gid" ] && [ "$sock_gid" != 0 ] && SOCK_GIDS+=("$sock_gid")
fi

# Anything the suite reaches on a HOST-published port needs an address that means the host from
# inside this container — its own 127.0.0.1 does not. host.docker.internal is native on Docker
# Desktop and synthesised by --add-host on Linux, so one spelling covers every host. Tier 3's
# fakes are the case in tree today; the same knob points a suite at a daemon on another machine.
HOST_ALIAS="${PITHEAD_TEST_HOST:-host.docker.internal}"
RUN=(--rm --user "$(id -u):$(id -g)"
--add-host "host.docker.internal:host-gateway"
-e "PITHEAD_TEST_HOST=$HOST_ALIAS"
-v "$HOME_VOLUME:/home/pithead"
"${MOUNTS[@]}")
for g in ${SOCK_GIDS[@]+"${SOCK_GIDS[@]}"}; do RUN+=(--group-add "$g"); done
[ -t 0 ] && [ -t 1 ] && RUN+=(-it)

[ "$#" -eq 0 ] && set -- make test
exec "$ENGINE" run "${RUN[@]}" "$IMAGE" "$@"
