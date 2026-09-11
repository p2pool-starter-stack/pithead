# The Linux toolchain `make test` assumes, as an image (#2078).
#
# This exists so a contributor on macOS or Windows can run tiers 1-3 and get the verdict CI gets.
# #2041 made the shell suite REFUSE on Darwin, because the assertions are written against GNU
# sed/stat and BSD tools differ without failing loudly — and because a host `grep` that is a ugrep
# shim silently matched nothing for a pattern holding a non-terminal `$`, which three reviewers
# read as evidence. A fallback cannot fix that class: the binary has the right name, the right
# flags, exit code 0, and the wrong answer. Only a known userland can.
#
# Same argument scripts/install-test-tools.sh makes for the bench's tool images, one level up:
# pinned images are visible to Dependabot and Trivy, host installs are not.
#
# Nothing here reaches a user. The release bundle (scripts/release/bundle.sh) and the appliance
# image (os/rootfs/Dockerfile) are strict allowlists of named paths, and no tests/ path can enter
# either — tests/stack/release asserts that rather than trusting it.
#
# Node is the awkward pin (CI runs 20, Debian ships 18), so the base solves it. Python is uv's
# job: dashboard/.python-version pins 3.11 and uv fetches it on first run.
FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0

# The versions come from the Makefile — it is the one place either is written (#1679, #1688) — and
# are passed in by scripts/test-container.sh via `make -s print-*-version`. The sha256s are tied to
# one tarball each, so bumping a version without its sha fails the build loudly instead of pulling
# something unverified. That is the same property ci.yml and shell.yml rely on for their copies.
ARG SHELLCHECK_VERSION
ARG SHFMT_VERSION
# Per-arch, because an image that skips the check on the host it actually runs on verifies
# nothing. The amd64 pair is byte-identical to the values shell.yml records; the arm64 pair was
# established the same way, from the upstream release.
ARG SHFMT_SHA256_amd64=fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1
ARG SHFMT_SHA256_arm64=32d92acaa5cd8abb29fc49dac123dc412442d5713967819d8af2c29f1b3857c7
ARG SHELLCHECK_SHA256_x86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ARG SHELLCHECK_SHA256_aarch64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588

# e2fsprogs: the shell suite builds loopback filesystems for the data-reset and hugepages fixtures.
# openssh-client: tier 4's live matrix drives a REMOTE box (`run.sh --host`), so the driver needs
# an ssh client even though nothing else here does.
# docker-cli + compose plugin: test-compose, test-mini-stack, test-netwatch and lint-proto all
# shell out to docker. The daemon is the HOST's, reached through the mounted socket.
# buildx is NOT optional here, and the failure it prevents is not obvious: without the plugin,
# `docker compose build` falls back to the classic builder, which rejects the
# `RUN --mount=type=cache` in dashboard/Dockerfile. Tier 3 dies at "docker compose build failed"
# with nothing pointing at the real cause. Measured, not guessed (#2078).
# hadolint ignore=DL3008,DL3009
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils curl e2fsprogs findutils git gnupg jq make \
    openssh-client \
    procps tar xz-utils \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# shellcheck + shfmt: direct upstream releases with a sha256 check, the same way shell.yml installs
# them. `make lint-sh` refuses any version that is not the pin, so a drifted image reds loudly.
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
    amd64) sc_arch=x86_64;  sh_sha="$SHFMT_SHA256_amd64"; sc_sha="$SHELLCHECK_SHA256_x86_64" ;; \
    arm64) sc_arch=aarch64; sh_sha="$SHFMT_SHA256_arm64"; sc_sha="$SHELLCHECK_SHA256_aarch64" ;; \
    *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/shfmt "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${arch}" \
    && echo "${sh_sha}  /tmp/shfmt" | sha256sum -c - \
    && install -m 0755 /tmp/shfmt /usr/local/bin/shfmt \
    && curl -fsSL -o /tmp/sc.tar.xz "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${sc_arch}.tar.xz" \
    && echo "${sc_sha}  /tmp/sc.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/sc.tar.xz -C /tmp \
    && install -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
    && rm -rf /tmp/shfmt /tmp/sc.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}"

# uv, pinned to the digest ci.yml installs (#2078: one uv, one lock, both sides).
COPY --from=ghcr.io/astral-sh/uv:0.10.10@sha256:cbe0a44ba994e327b8fe7ed72beef1aaa7d2c4c795fd406d1dbf328bacb2f1c5 /uv /uvx /usr/local/bin/

# The suite expects a NON-ROOT user: several fixtures assert permission-denied, and root bypasses
# every one of them — they would pass while proving nothing. UID/GID come from the invoking host so
# files written into the mounted repo keep the caller's ownership on Linux too, not just on the
# Docker Desktop file-sharing layer. The group may already exist (macOS gid 20 is `dialout` here),
# which is why the groupadd is allowed to fail.
ARG PITHEAD_UID=1000
ARG PITHEAD_GID=1000
RUN groupadd -g "$PITHEAD_GID" pithead 2>/dev/null || true; \
    useradd -u "$PITHEAD_UID" -g "$PITHEAD_GID" -m -d /home/pithead -s /bin/bash pithead 2>/dev/null || true; \
    mkdir -p /home/pithead && chown -R "$PITHEAD_UID:$PITHEAD_GID" /home/pithead
USER $PITHEAD_UID:$PITHEAD_GID
ENV HOME=/home/pithead
# npx and uvx download on first use, exactly as they do in CI. The runner script keeps HOME on a
# named volume so that cost is paid once per machine rather than once per run.
# The uv cache lives on the named volume and the project on the bind mount — different
# filesystems, so hardlinking cannot work and uv warns on every run. Copy is the honest mode.
ENV UV_LINK_MODE=copy
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
CMD ["make", "test"]
