ARG GO_IMAGE
ARG RUNNER_IMAGE
FROM ${GO_IMAGE} AS go
FROM ${RUNNER_IMAGE}
USER root
RUN printf '%s\n' \
    'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian/20261102T000000Z/ bookworm main' \
    'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian/20261102T000000Z/ bookworm-updates main' \
    'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian-security/20261102T000000Z/ bookworm-security main' \
    >/tmp/pithead-snapshot.list \
    && apt-get -o Dir::Etc::sourcelist=/tmp/pithead-snapshot.list -o Dir::Etc::sourceparts=- update \
    && apt-get -o Dir::Etc::sourcelist=/tmp/pithead-snapshot.list -o Dir::Etc::sourceparts=- install -y --no-install-recommends \
    systemd=252.39-1~deb12u2 gcc=4:12.2.0-3 libc6-dev=2.36-9+deb12u14 gettext-base=0.21-12 \
    && rm -f /tmp/pithead-snapshot.list && rm -rf /var/lib/apt/lists/*
COPY --from=go /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:${PATH}"
ARG TOOLS_REVISION
LABEL io.pithead.test-runner.tools="${TOOLS_REVISION}"
USER pithead
