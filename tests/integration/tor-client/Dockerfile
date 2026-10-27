FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

RUN apk add --no-cache --upgrade libcrypto3 libssl3 tor curl ca-certificates

COPY probe.sh /usr/local/bin/probe.sh
RUN chmod 0755 /usr/local/bin/probe.sh

# Drop privileges — the probe needs no root (tor runs fine as an unprivileged user with a tmpdir).
USER tor
ENTRYPOINT ["/usr/local/bin/probe.sh"]
