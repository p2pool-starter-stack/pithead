FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache --upgrade libcrypto3 libssl3 musl musl-utils tor curl ca-certificates

COPY probe.sh /usr/local/bin/probe.sh
RUN chmod 0755 /usr/local/bin/probe.sh

# Drop privileges — the probe needs no root (tor runs fine as an unprivileged user with a tmpdir).
USER tor
ENTRYPOINT ["/usr/local/bin/probe.sh"]
